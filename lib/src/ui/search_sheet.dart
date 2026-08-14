import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../geo/coordinate_formats.dart';
import '../geo/coordinate_parser.dart';

/// Offline place search (FR-8.1).
///
/// Searches the bundled database as the user types. Nothing here touches the
/// network, so it behaves identically in airplane mode — which is the point.
class SearchSheet extends StatefulWidget {
  const SearchSheet({
    super.key,
    required this.onSearch,
    required this.onSelected,
    this.onCoordinate,
    this.debounce = const Duration(milliseconds: 180),
  });

  /// Runs the query. Returns results already carrying distance and bearing.
  final Future<List<PlaceSearchResult>> Function(String query) onSearch;

  final ValueChanged<PlaceSearchResult> onSelected;

  /// Called when the user picks a coordinate they typed or pasted (FR-8.2).
  final ValueChanged<ParsedCoordinate>? onCoordinate;

  /// How long to wait after the last keystroke before querying.
  ///
  /// Injectable so tests need not sleep. A search is a couple of milliseconds,
  /// but firing one per keystroke still means throwing most of them away.
  final Duration debounce;

  @override
  State<SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<SearchSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  List<PlaceSearchResult> _results = const [];
  bool _searching = false;
  String _lastQuery = '';

  /// Set when the typed text is itself a position (FR-8.2).
  ParsedCoordinate? _coordinate;

  /// Guards against an earlier, slower query overwriting a later one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (widget.debounce == Duration.zero) {
      unawaited(_run(value));
      return;
    }
    _debounce = Timer(widget.debounce, () => unawaited(_run(value)));
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      if (mounted) {
        setState(() {
          _results = const [];
          _searching = false;
          _lastQuery = '';
        });
      }
      return;
    }

    // FR-8.2: the text may be a position rather than a name. Parsing is
    // instant and local, so it happens before the query rather than after it.
    final coordinate = parseCoordinate(trimmed);

    setState(() {
      _searching = true;
      _coordinate = coordinate;
    });
    final results = await widget.onSearch(trimmed);

    // A slower earlier query must not clobber a later one's results.
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = results;
      _searching = false;
      _lastQuery = trimmed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'Search places',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear',
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                        setState(() {});
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        if (_searching)
          const LinearProgressIndicator(minHeight: 2)
        else
          const SizedBox(height: 2),
        Flexible(child: _body(theme)),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    if (_controller.text.trim().isEmpty) {
      return _hint(
        theme,
        Icons.travel_explore,
        'Search 235,242 places',
        'Works with no signal. Nothing is sent anywhere.',
      );
    }
    final coordinate = _coordinate;

    if (_results.isEmpty && coordinate == null && !_searching &&
        _lastQuery.isNotEmpty) {
      return _hint(
        theme,
        Icons.search_off,
        'No match for "$_lastQuery"',
        'Only populated places are in the offline database. '
            'Coordinates and Plus Codes also work here.',
      );
    }

    // A recognised coordinate leads, because someone who pasted one is not
    // looking for a name that happens to contain the same digits.
    final leading = coordinate == null ? 0 : 1;

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length + leading,
      itemBuilder: (context, index) {
        if (coordinate != null && index == 0) {
          return _coordinateTile(theme, coordinate);
        }

        final result = _results[index - leading];
        final distance = result.distanceKm;

        return ListTile(
          dense: true,
          leading: const Icon(Icons.place_outlined, size: 20),
          title: Text(result.place.name),
          subtitle: Text(
            result.place.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // FR-8.1 asks for distance and bearing from the current position. A
          // compass point is what someone standing in a field can act on.
          trailing: distance == null
              ? null
              : Text(
                  '${_distance(distance)}\n${result.compassPoint}',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
          isThreeLine: false,
          onTap: () => widget.onSelected(result),
        );
      },
    );
  }

  /// Offers a position the user typed or pasted (FR-8.2).
  ///
  /// States which notation was recognised. Several of them look alike at a
  /// glance, and confirming the reading is what stops a misread going
  /// unnoticed.
  Widget _coordinateTile(ThemeData theme, ParsedCoordinate coordinate) {
    return ListTile(
      dense: true,
      leading: Icon(Icons.my_location, size: 20,
          color: theme.colorScheme.tertiary),
      title: Text(
        formatDecimalDegrees(coordinate.latitude, coordinate.longitude),
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      subtitle: Text('Read as ${coordinate.format.label}'),
      onTap: widget.onCoordinate == null
          ? null
          : () => widget.onCoordinate!(coordinate),
    );
  }

  Widget _hint(
    ThemeData theme,
    IconData icon,
    String title,
    String body,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _distance(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    if (km < 100) return '${km.toStringAsFixed(1)} km';
    return '${km.round()} km';
  }
}
