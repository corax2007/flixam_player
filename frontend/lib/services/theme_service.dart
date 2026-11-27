import 'package:flutter/material.dart';

/// Fünf auswählbare Oberflächen-Designs. Alle Varianten sind dunkel, damit
/// Text/Player-Overlays überall lesbar bleiben; sie unterscheiden sich in
/// Grundfarbe, Kartenfläche und Akzentfarbe.
class FlixamDesign {
  final String id;
  final String name;
  final Color background;
  final Color surface;
  final Color accent;
  final Color accentSoft;
  final Color overlay;
  final BorderRadius radius;

  const FlixamDesign({
    required this.id,
    required this.name,
    required this.background,
    required this.surface,
    required this.accent,
    required this.accentSoft,
    required this.overlay,
    this.radius = const BorderRadius.all(Radius.circular(12)),
  });
}

const List<FlixamDesign> flixamDesigns = [
  FlixamDesign(
    id: 'classic',
    name: 'Klassisch',
    background: Color(0xFF0A0A0C),
    surface: Color(0xFF16161A),
    accent: Colors.redAccent,
    accentSoft: Color(0x33FF5252),
    overlay: Color(0xB3000000),
  ),
  FlixamDesign(
    id: 'midnight',
    name: 'Mitternacht',
    background: Color(0xFF070B14),
    surface: Color(0xFF101A2B),
    accent: Color(0xFF4FC3F7),
    accentSoft: Color(0x334FC3F7),
    overlay: Color(0xB3050B14),
  ),
  FlixamDesign(
    id: 'forest',
    name: 'Wald',
    background: Color(0xFF07100C),
    surface: Color(0xFF102018),
    accent: Color(0xFF66BB6A),
    accentSoft: Color(0x3366BB6A),
    overlay: Color(0xB307100C),
  ),
  FlixamDesign(
    id: 'violet',
    name: 'Violett',
    background: Color(0xFF0C0814),
    surface: Color(0xFF1B1230),
    accent: Color(0xFFCE93D8),
    accentSoft: Color(0x33CE93D8),
    overlay: Color(0xB30C0814),
  ),
  FlixamDesign(
    id: 'amber',
    name: 'Amber',
    background: Color(0xFF100C08),
    surface: Color(0xFF211A12),
    accent: Color(0xFFFFB74D),
    accentSoft: Color(0x33FFB74D),
    overlay: Color(0xB3100C08),
  ),
];

FlixamDesign designAt(int index) =>
    flixamDesigns[index.clamp(0, flixamDesigns.length - 1)];

ThemeData flixamTheme(int index) {
  final d = designAt(index);
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: d.background,
    canvasColor: d.background,
    cardColor: d.surface,
    dialogTheme: DialogThemeData(backgroundColor: d.surface),
    dividerColor: d.surface.withValues(alpha: 0.6),
    hintColor: Colors.white54,
    colorScheme: ColorScheme.dark(
      primary: d.accent,
      secondary: d.accent,
      surface: d.surface,
      onSurface: Colors.white,
      error: Colors.redAccent,
    ),
    iconTheme: const IconThemeData(color: Colors.white70),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Colors.white),
      bodyMedium: TextStyle(color: Colors.white),
      titleLarge: TextStyle(color: Colors.white),
      titleMedium: TextStyle(color: Colors.white),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: d.accent,
      inactiveTrackColor: Colors.white24,
      thumbColor: d.accent,
      overlayColor: d.accentSoft,
      valueIndicatorColor: d.accent,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: d.surface,
      selectedColor: d.accentSoft,
      labelStyle: const TextStyle(color: Colors.white, fontSize: 11),
      secondaryLabelStyle: const TextStyle(color: Colors.white, fontSize: 11),
      brightness: Brightness.dark,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: d.surface,
      hintStyle: const TextStyle(color: Colors.white38),
      border: OutlineInputBorder(
        borderRadius: d.radius,
        borderSide: BorderSide.none,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: d.accent,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: d.radius),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(d.surface),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: d.radius),
        ),
      ),
    ),
  );
}

Color bg(BuildContext context) => Theme.of(context).scaffoldBackgroundColor;
Color surf(BuildContext context) => Theme.of(context).colorScheme.surface;
Color accent(BuildContext context) => Theme.of(context).colorScheme.primary;

/// Layout-Presets. 0 = bisherige Kopfzeile, 1 = Aether mit Seitenleiste.
class FlixamLayout {
  final String name;
  final String description;
  const FlixamLayout(this.name, this.description);
}

const List<FlixamLayout> flixamLayouts = [
  FlixamLayout('Klassisch', 'Kopfzeile oben'),
  FlixamLayout('Aether', 'Seitenleiste links'),
];

/// Ansichts-Modi für die Cover-Reihen (rechtes Auswahl-Panel).
const List<String> flixamViewModes = [
  'Liste',
  'Rechte Liste',
  'Fanartliste',
  'ListeUnten',
  'GroßeListe',
  'Logo',
  'SchauKasten',
  'Shift',
  'Poster',
  'MyFlix',
  'Tri-Panel',
  'Symbole',
  'Wand',
  'Vollbildwand',
  'InfoWand',
];
