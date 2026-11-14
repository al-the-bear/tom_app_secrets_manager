// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The app's look: a compact Material 3 theme for a desktop tool, a colour
/// per vault and per entry type, type avatars, tinted chips and section
/// cards. Colours stay readable through `tom_reusable_ui`'s
/// `tomReadableOn` / `tomTintedChip`.
library;

import 'package:flutter/material.dart';
import 'package:tom_reusable_ui/tom_reusable_ui.dart'
    show tomReadableOn, tomTintedChip;
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// The seed colour of the app's scheme.
const Color tomSecretsSeed = Color(0xFF2E6B5A);

/// The app's theme in [brightness]: compact density, smaller type in lists
/// and fields, outlined dense inputs, flat cards.
ThemeData tomSecretsTheme(Brightness brightness) {
  final base = ThemeData(
    colorSchemeSeed: tomSecretsSeed,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
  );
  final scheme = base.colorScheme;
  final text = base.textTheme;
  return base.copyWith(
    textTheme: text.copyWith(
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 14),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 13),
      bodySmall: text.bodySmall?.copyWith(fontSize: 11.5),
      titleMedium: text.titleMedium?.copyWith(fontSize: 14.5),
      titleSmall: text.titleSmall?.copyWith(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      labelLarge: text.labelLarge?.copyWith(fontSize: 13),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      horizontalTitleGap: 10,
      minLeadingWidth: 20,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      selectedColor: scheme.onSecondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      titleTextStyle: text.bodyMedium?.copyWith(
        fontSize: 13,
        color: scheme.onSurface,
      ),
      subtitleTextStyle: text.bodySmall?.copyWith(
        fontSize: 11.5,
        color: scheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    iconTheme: base.iconTheme.copyWith(size: 20),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
      labelType: NavigationRailLabelType.all,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}

const List<Color> _vaultPalette = [
  Color(0xFF1E88E5),
  Color(0xFF8E24AA),
  Color(0xFF00897B),
  Color(0xFFF4511E),
  Color(0xFF3949AB),
  Color(0xFF7CB342),
  Color(0xFFD81B60),
  Color(0xFF6D4C41),
];

/// The colour of the vault [store], the same on every start.
Color tomSecretsVaultColour(String store) {
  var h = 0;
  for (final c in store.codeUnits) {
    h = (h * 31 + c) % 0x7fffffff;
  }
  return _vaultPalette[h % _vaultPalette.length];
}

/// The colour of an entry [type].
Color tomSecretsTypeColour(TomSecretsEntryType type) => switch (type) {
  TomSecretsEntryType.apiToken => const Color(0xFFE6A100),
  TomSecretsEntryType.note => const Color(0xFF43A047),
  TomSecretsEntryType.sshKey => const Color(0xFF5E35B1),
  TomSecretsEntryType.certificate => const Color(0xFF00838F),
  TomSecretsEntryType.pgpKey => const Color(0xFF6D4C41),
  TomSecretsEntryType.login => const Color(0xFF1E88E5),
};

/// The icon of an entry [type].
IconData tomSecretsTypeIcon(TomSecretsEntryType type) => switch (type) {
  TomSecretsEntryType.apiToken => Icons.vpn_key_rounded,
  TomSecretsEntryType.note => Icons.sticky_note_2_rounded,
  TomSecretsEntryType.sshKey => Icons.terminal_rounded,
  TomSecretsEntryType.certificate => Icons.verified_rounded,
  TomSecretsEntryType.pgpKey => Icons.enhanced_encryption_rounded,
  TomSecretsEntryType.login => Icons.person_rounded,
};

/// A round avatar in [colour] with [icon].
class TomSecretsAvatar extends StatelessWidget {
  /// An avatar of [icon] in [colour], [size] across.
  const TomSecretsAvatar({
    super.key,
    required this.icon,
    required this.colour,
    this.size = 28,
  });

  /// The icon.
  final IconData icon;

  /// The colour.
  final Color colour;

  /// The diameter.
  final double size;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final chip = tomTintedChip(colour, surface);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Color.alphaBlend(colour.withValues(alpha: 0.18), surface),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size * 0.58, color: chip.foreground),
    );
  }
}

/// The avatar of an entry [type].
class TomSecretsTypeAvatar extends StatelessWidget {
  /// The avatar of [type].
  const TomSecretsTypeAvatar(this.type, {super.key, this.size = 28});

  /// The type.
  final TomSecretsEntryType type;

  /// The diameter.
  final double size;

  @override
  Widget build(BuildContext context) => TomSecretsAvatar(
    icon: tomSecretsTypeIcon(type),
    colour: tomSecretsTypeColour(type),
    size: size,
  );
}

/// A small tinted chip: a tag, a badge.
class TomSecretsChip extends StatelessWidget {
  /// A chip saying [label] in [colour], with an optional [icon].
  const TomSecretsChip(this.label, {super.key, this.colour, this.icon});

  /// What it says.
  final String label;

  /// Its hue (default the scheme's tertiary).
  final Color? colour;

  /// An icon before the label.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = tomTintedChip(colour ?? scheme.tertiary, scheme.surface);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border, width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: c.foreground),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: c.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// The colour of a tag: a stable hue per tag text.
Color tomSecretsTagColour(String tag) => tomSecretsVaultColour('#$tag');

/// A section of a form: a card with an icon and a title.
class TomSecretsSection extends StatelessWidget {
  /// A section titled [title] with [icon].
  const TomSecretsSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
  });

  /// The title.
  final String title;

  /// The icon beside it.
  final IconData icon;

  /// The content.
  final List<Widget> children;

  /// An action at the right of the title.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// [colour] made readable on the theme's surface, for icons.
Color tomSecretsOnSurface(BuildContext context, Color colour) =>
    tomReadableOn(colour, Theme.of(context).colorScheme.surface, ratio: 3);
