import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 星愿 design tokens (雾青纸感). One accent, misty teal; gold is reserved
/// for stars and text never uses it.
@immutable
class XyColors extends ThemeExtension<XyColors> {
  const XyColors({
    required this.sky,
    required this.skyDeep,
    required this.onSky,
    required this.onSkyMuted,
    required this.skyLine,
    required this.star,
    required this.partner,
    required this.partnerText,
    required this.partnerSoft,
    required this.muted,
    required this.faint,
    required this.line,
    required this.card,
    required this.cardSoft,
    required this.fill,
    required this.bar,
    required this.success,
    required this.warning,
    required this.warningSoft,
  });

  final Color sky;
  final Color skyDeep;
  final Color onSky;
  final Color onSkyMuted;
  final Color skyLine;
  final Color star;
  final Color partner;
  final Color partnerText;
  final Color partnerSoft;

  /// Secondary label.
  final Color muted;

  /// Tertiary label, for placeholders and inactive glyphs.
  final Color faint;

  /// Hairline separator.
  final Color line;

  /// Grouped content background.
  final Color card;

  /// A well inside a card, such as a quoted note.
  final Color cardSoft;

  /// Fill for fields, segmented controls and secondary buttons.
  final Color fill;

  /// Navigation and tab bar chrome.
  final Color bar;
  final Color success;
  final Color warning;
  final Color warningSoft;

  // 雾青纸感: a quiet paper ground, one misty-teal accent, gold only for
  // stars. The "sky" is a pale dawn wash, not a night band.
  static const light = XyColors(
    sky: Color(0xFFEFF4F1),
    skyDeep: Color(0xFFE4ECE8),
    onSky: Color(0xFF1E2925),
    onSkyMuted: Color(0xFF5F6B66),
    skyLine: Color(0xFFD5DED9),
    star: Color(0xFFD9A441),
    partner: Color(0xFFE58B7B),
    partnerText: Color(0xFFA9503F),
    partnerSoft: Color(0xFFFBEDE9),
    muted: Color(0xFF66716C),
    faint: Color(0xFFA3ACA7),
    line: Color(0xFFE3E7E1),
    card: Color(0xFFFFFFFF),
    cardSoft: Color(0xFFF3F5F1),
    fill: Color(0xFFECEFEA),
    bar: Color(0xFFFBFBF8),
    success: Color(0xFF3F7D5C),
    warning: Color(0xFFA9621B),
    warningSoft: Color(0xFFFBF1E4),
  );

  static const dark = XyColors(
    sky: Color(0xFF1D2724),
    skyDeep: Color(0xFF151D1A),
    onSky: Color(0xFFEDF1EE),
    onSkyMuted: Color(0xFFA9B6B0),
    skyLine: Color(0xFF2C3733),
    star: Color(0xFFE7B95A),
    partner: Color(0xFFF0A090),
    partnerText: Color(0xFFF2AB9D),
    partnerSoft: Color(0xFF3A2622),
    muted: Color(0xFF9AA59F),
    faint: Color(0xFF5F6A65),
    line: Color(0xFF2A302D),
    card: Color(0xFF1C211F),
    cardSoft: Color(0xFF232926),
    fill: Color(0xFF2A302D),
    bar: Color(0xFF181C1A),
    success: Color(0xFF7FC29B),
    warning: Color(0xFFE0A15A),
    warningSoft: Color(0xFF33281A),
  );

  @override
  XyColors copyWith({
    Color? sky,
    Color? skyDeep,
    Color? onSky,
    Color? onSkyMuted,
    Color? skyLine,
    Color? star,
    Color? partner,
    Color? partnerText,
    Color? partnerSoft,
    Color? muted,
    Color? faint,
    Color? line,
    Color? card,
    Color? cardSoft,
    Color? fill,
    Color? bar,
    Color? success,
    Color? warning,
    Color? warningSoft,
  }) => XyColors(
    sky: sky ?? this.sky,
    skyDeep: skyDeep ?? this.skyDeep,
    onSky: onSky ?? this.onSky,
    onSkyMuted: onSkyMuted ?? this.onSkyMuted,
    skyLine: skyLine ?? this.skyLine,
    star: star ?? this.star,
    partner: partner ?? this.partner,
    partnerText: partnerText ?? this.partnerText,
    partnerSoft: partnerSoft ?? this.partnerSoft,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    line: line ?? this.line,
    card: card ?? this.card,
    cardSoft: cardSoft ?? this.cardSoft,
    fill: fill ?? this.fill,
    bar: bar ?? this.bar,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    warningSoft: warningSoft ?? this.warningSoft,
  );

  @override
  XyColors lerp(XyColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return XyColors(
      sky: mix(sky, other.sky),
      skyDeep: mix(skyDeep, other.skyDeep),
      onSky: mix(onSky, other.onSky),
      onSkyMuted: mix(onSkyMuted, other.onSkyMuted),
      skyLine: mix(skyLine, other.skyLine),
      star: mix(star, other.star),
      partner: mix(partner, other.partner),
      partnerText: mix(partnerText, other.partnerText),
      partnerSoft: mix(partnerSoft, other.partnerSoft),
      muted: mix(muted, other.muted),
      faint: mix(faint, other.faint),
      line: mix(line, other.line),
      card: mix(card, other.card),
      cardSoft: mix(cardSoft, other.cardSoft),
      fill: mix(fill, other.fill),
      bar: mix(bar, other.bar),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      warningSoft: mix(warningSoft, other.warningSoft),
    );
  }
}

extension XyTheme on BuildContext {
  XyColors get xy =>
      Theme.of(this).extension<XyColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? XyColors.dark
          : XyColors.light);

  /// True where the app should use native iOS controls and dialogs.
  bool get isCupertino => switch (Theme.of(this).platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };
}

/// Inset-grouped sections and cards.
const xyCardRadius = 20.0;

/// Prominent buttons.
const xyButtonRadius = 14.0;

/// The bundled serif (Noto Serif SC subset) for titles and written words.
const xySerif = 'XySerif';

ThemeData buildXyTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final xy = dark ? XyColors.dark : XyColors.light;
  final background = dark ? const Color(0xFF141816) : const Color(0xFFF5F6F2);
  final ink = dark ? const Color(0xFFEDF1EE) : const Color(0xFF1E2925);
  final primary = dark ? const Color(0xFF8DBBAE) : const Color(0xFF4E7D72);
  final onPrimary = dark ? const Color(0xFF10201B) : Colors.white;
  final primaryContainer = dark
      ? const Color(0xFF24332F)
      : const Color(0xFFE6EFEC);
  final onPrimaryContainer = dark
      ? const Color(0xFFCFE5DE)
      : const Color(0xFF2D4F47);
  final error = dark ? const Color(0xFFFF7A6E) : const Color(0xFFC0443A);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: xy.partnerText,
    onSecondary: Colors.white,
    secondaryContainer: xy.partnerSoft,
    onSecondaryContainer: dark
        ? const Color(0xFFFFDAD3)
        : const Color(0xFF5C1D12),
    tertiary: xy.star,
    onTertiary: const Color(0xFF2A1F05),
    error: error,
    onError: Colors.white,
    errorContainer: dark ? const Color(0xFF3A201D) : const Color(0xFFFBEBE8),
    onErrorContainer: dark ? const Color(0xFFFFB4AB) : const Color(0xFF7E271F),
    surface: background,
    onSurface: ink,
    onSurfaceVariant: xy.muted,
    surfaceContainerLowest: xy.card,
    surfaceContainerLow: xy.card,
    surfaceContainer: xy.card,
    surfaceContainerHigh: xy.cardSoft,
    surfaceContainerHighest: xy.fill,
    outline: xy.faint,
    outlineVariant: xy.line,
    inverseSurface: dark ? const Color(0xFFEDF1EE) : const Color(0xFF1E2925),
    onInverseSurface: dark ? const Color(0xFF141816) : const Color(0xFFF5F6F2),
    inversePrimary: dark ? const Color(0xFF4E7D72) : const Color(0xFFA9CCC2),
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
  );
  // iOS text styles: Large Title 34, Title 28/22/20, Headline 17 semibold,
  // Body 17, Subheadline 15, Footnote 13, Caption 12. The platform supplies
  // the font (SF Pro with PingFang for Chinese on iOS).
  TextStyle? tune(
    TextStyle? style,
    double size,
    FontWeight weight, {
    double height = 1.35,
    double spacing = 0,
    bool serif = false,
  }) => style?.copyWith(
    fontSize: size,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height,
    fontFamily: serif ? xySerif : null,
  );
  final text = base.textTheme;
  final textTheme = text
      .copyWith(
        // Titles are set in the serif, like headings on paper; controls and
        // running UI text stay in the system sans (PingFang on iOS).
        displaySmall: tune(
          text.displaySmall,
          32,
          FontWeight.w600,
          height: 1.25,
          serif: true,
        ),
        headlineLarge: tune(
          text.headlineLarge,
          32,
          FontWeight.w600,
          height: 1.25,
          serif: true,
        ),
        headlineMedium: tune(
          text.headlineMedium,
          26,
          FontWeight.w600,
          height: 1.3,
          serif: true,
        ),
        headlineSmall: tune(
          text.headlineSmall,
          22,
          FontWeight.w600,
          height: 1.35,
          serif: true,
        ),
        titleLarge: tune(
          text.titleLarge,
          19,
          FontWeight.w600,
          height: 1.35,
          serif: true,
        ),
        titleMedium: tune(text.titleMedium, 17, FontWeight.w600),
        titleSmall: tune(text.titleSmall, 15, FontWeight.w600),
        bodyLarge: tune(text.bodyLarge, 17, FontWeight.w400),
        bodyMedium: tune(text.bodyMedium, 15, FontWeight.w400),
        bodySmall: tune(text.bodySmall, 13, FontWeight.w400),
        labelLarge: tune(text.labelLarge, 16, FontWeight.w600),
        labelMedium: tune(text.labelMedium, 13, FontWeight.w500),
        labelSmall: tune(text.labelSmall, 12, FontWeight.w500),
      )
      .apply(bodyColor: ink, displayColor: ink);

  const buttonShape = StadiumBorder();
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: BorderSide(color: xy.line),
  );
  const cupertinoTransitions = CupertinoPageTransitionsBuilder();
  return base.copyWith(
    textTheme: textTheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    extensions: [xy],
    // Press feedback is a highlight or a fade, as on iOS, never a ripple.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: ink.withValues(alpha: dark ? 0.12 : 0.08),
    hoverColor: Colors.transparent,
    focusColor: primary.withValues(alpha: 0.12),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: cupertinoTransitions,
        TargetPlatform.iOS: cupertinoTransitions,
        TargetPlatform.macOS: cupertinoTransitions,
        TargetPlatform.linux: cupertinoTransitions,
        TargetPlatform.windows: cupertinoTransitions,
        TargetPlatform.fuchsia: cupertinoTransitions,
      },
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: primary,
      scaffoldBackgroundColor: background,
      barBackgroundColor: xy.bar.withValues(alpha: 0.94),
    ),
    appBarTheme: AppBarTheme(
      // Blends with the page at rest and turns to bar chrome once content
      // scrolls underneath, like a UINavigationBar.
      backgroundColor: WidgetStateColor.resolveWith(
        (states) =>
            states.contains(WidgetState.scrolledUnder) ? xy.bar : background,
      ),
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: true,
      toolbarHeight: 48,
      iconTheme: IconThemeData(color: primary, size: 24),
      actionsIconTheme: IconThemeData(color: primary, size: 24),
      titleTextStyle: textTheme.titleMedium,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: xy.card,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(xyCardRadius),
        side: BorderSide(color: xy.line),
      ),
    ),
    dividerTheme: DividerThemeData(color: xy.line, thickness: 0.5, space: 0.5),
    listTileTheme: ListTileThemeData(
      iconColor: primary,
      textColor: ink,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: xy.muted),
      leadingAndTrailingTextStyle: textTheme.bodyLarge?.copyWith(
        color: xy.muted,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 11,
      minTileHeight: 48,
      horizontalTitleGap: 12,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: xy.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      disabledBorder: fieldBorder,
      focusedBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: primary.withValues(alpha: 0.6)),
      ),
      errorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: error, width: 1),
      ),
      focusedErrorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: error, width: 1),
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      labelStyle: textTheme.bodyMedium?.copyWith(color: xy.muted),
      floatingLabelStyle: textTheme.bodyMedium?.copyWith(color: xy.muted),
      hintStyle: textTheme.bodyLarge?.copyWith(color: xy.faint),
      helperStyle: textTheme.bodySmall?.copyWith(color: xy.muted),
      counterStyle: textTheme.bodySmall?.copyWith(color: xy.faint),
      errorStyle: textTheme.bodySmall?.copyWith(color: error),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: primary,
      selectionColor: primary.withValues(alpha: 0.25),
      selectionHandleColor: primary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 50)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
        shape: const WidgetStatePropertyAll(buttonShape),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: WidgetStatePropertyAll(
          textTheme.labelLarge?.copyWith(fontSize: 17),
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return xy.fill;
          if (states.contains(WidgetState.pressed)) {
            return primary.withValues(alpha: 0.7);
          }
          return primary;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? xy.faint : onPrimary,
        ),
      ),
    ),
    // iOS "tinted" buttons: a soft wash of the accent, no outline.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
        shape: const WidgetStatePropertyAll(buttonShape),
        side: const WidgetStatePropertyAll(BorderSide.none),
        textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return xy.fill;
          return primary.withValues(
            alpha: states.contains(WidgetState.pressed) ? 0.22 : 0.12,
          );
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? xy.faint : primary,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        textStyle: WidgetStatePropertyAll(
          textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return xy.faint;
          if (states.contains(WidgetState.pressed)) {
            return primary.withValues(alpha: 0.35);
          }
          return primary;
        }),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? ink.withValues(alpha: 0.06)
              : Colors.transparent,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: xy.bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: 0,
      height: 56,
      labelPadding: const EdgeInsets.only(top: 2),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelSmall?.copyWith(
          fontSize: 11,
          height: 1.2,
          color: states.contains(WidgetState.selected) ? primary : xy.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? primary : xy.faint,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: WidgetStatePropertyAll(dark ? xy.card : Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? primary : xy.fill,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: BorderSide(color: xy.faint, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? primary
            : Colors.transparent,
      ),
    ),
    chipTheme: ChipThemeData(
      showCheckmark: false,
      backgroundColor: xy.fill,
      selectedColor: primary,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
      secondaryLabelStyle: textTheme.bodyMedium?.copyWith(
        color: onPrimary,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: dark ? const Color(0xFF2A302D) : const Color(0xFF1E2925),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      actionTextColor: dark ? primary : const Color(0xFFA9CCC2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: xy.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: textTheme.titleMedium,
      contentTextStyle: textTheme.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: xy.card,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: xy.faint,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: xy.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: xy.card,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: xy.card,
      headerForegroundColor: ink,
      headerHeadlineStyle: textTheme.titleLarge,
      dividerColor: xy.line,
      todayBorder: BorderSide.none,
      todayForegroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? onPrimary : primary,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: xy.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: xy.muted,
      linearTrackColor: xy.fill,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: dark ? const Color(0xFFF0A090) : const Color(0xFFD9675A),
      textColor: dark ? const Color(0xFF2A1410) : Colors.white,
    ),
    tooltipTheme: const TooltipThemeData(
      // iOS has no long-press tooltips; the message still labels the control
      // for VoiceOver.
      triggerMode: TooltipTriggerMode.manual,
    ),
  );
}
