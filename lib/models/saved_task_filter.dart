/// Named task-manager views. Kept with workspace preferences in schema 16.
class SavedTaskFilter {
  const SavedTaskFilter({
    required this.id,
    required this.name,
    required this.view,
    required this.query,
  });

  static const storageKey = 'savedTaskFilters';
  static const maxCount = 12;
  static const maxNameLength = 64;
  static const maxQueryLength = 240;
  static const views = {'manage', 'pause', 'trash', 'archive', 'history'};
  final String id, name, view, query;

  bool matches(String selectedView, String selectedQuery) =>
      view == selectedView && query == selectedQuery.trim();

  bool sameAs(SavedTaskFilter other) =>
      id == other.id &&
      name == other.name &&
      view == other.view &&
      query == other.query;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'view': view,
    'query': query,
  };

  SavedTaskFilter renamed(String value) =>
      SavedTaskFilter(id: id, name: value.trim(), view: view, query: query);

  static bool validName(String value) =>
      value.trim().isNotEmpty &&
      value == value.trim() &&
      value.length <= maxNameLength &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  factory SavedTaskFilter.fromJson(dynamic raw) {
    if (raw is! Map ||
        raw.length != 4 ||
        !raw.keys.toSet().containsAll({'id', 'name', 'view', 'query'}) ||
        raw['id'] is! String ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$').hasMatch(raw['id']) ||
        raw['name'] is! String ||
        !validName(raw['name']) ||
        !views.contains(raw['view']) ||
        raw['query'] is! String ||
        raw['query'].length > maxQueryLength ||
        raw['query'] != raw['query'].trim()) {
      throw const FormatException('Invalid saved task filter');
    }
    return SavedTaskFilter(
      id: raw['id'],
      name: raw['name'],
      view: raw['view'],
      query: raw['query'],
    );
  }

  static List<SavedTaskFilter> decode(dynamic raw) {
    if (raw == null) return const [];
    if (raw is! Map ||
        raw.length != 2 ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['items'] is! List ||
        raw['items'].length > maxCount) {
      throw const FormatException('Invalid saved task filters');
    }
    final items = (raw['items'] as List).map(SavedTaskFilter.fromJson).toList();
    if (items.map((e) => e.id).toSet().length != items.length ||
        items.map((e) => e.name.toLowerCase()).toSet().length != items.length) {
      throw const FormatException('Duplicate saved task filter');
    }
    return List.unmodifiable(items);
  }

  static Map<String, dynamic> encode(Iterable<SavedTaskFilter> filters) {
    final raw = {
      'version': 1,
      'items': filters.map((e) => e.toJson()).toList(),
    };
    decode(raw);
    return raw;
  }
}
