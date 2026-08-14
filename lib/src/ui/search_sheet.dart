import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';

/// Offline place search (FR-8.1).
///
/// Searches the bundled database as the user types. Nothing here touches the
/// network, so it behaves identically in airplane mode — which is the point.
class SearchSheet extends StatefulWidget {
  const SearchSheet({
    super.key,
    required this.onSearch,
    required this.onSelected,
    this.debounce = const Duration(milliseconds: 180),
  });

  /// Runs the query. Returns results already carrying distance and bearing.
  final Future<List<PlaceSearchResult>> Function(String query) onSearch;

  final ValueChanged<PlaceSearchResult> onSelected;

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

    setState(() => _searching = true);
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
    if (_results.isEmpty && !_searching && _lastQuery.isNotEmpty) {
      return _hint(
        theme,
        Icons.search_off,
        'No match for "$_lastQuery"',
        'Only populated places are in the offline database.',
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final result = _results[i];
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
