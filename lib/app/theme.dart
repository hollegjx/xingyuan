import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 星愿 design tokens, built on the iOS system palette. Gold is reserved for
/// stars; text never uses it.
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

  static const light = XyColors(
    sky: Color(0xFF232750),
    skyDeep: Color(0xFF12142C),
    onSky: Color(0xFFF5F4FF),
    onSkyMuted: Color(0xFFB9BBE0),
    skyLine: Color(0xFF3A3F72),
    star: Color(0xFFF7B32B),
    partner: Color(0xFFFF7A6B),
    partnerText: Color(0xFFC4402F),
    partnerSoft: Color(0xFFFFEDEA),
    muted: Color(0xFF6E6E73),
    faint: Color(0xFFAEAEB2),
    line: Color(0xFFD8D8DC),
    card: Color(0xFFFFFFFF),
    cardSoft: Color(0xFFF4F4F7),
    fill: Color(0xFFE9E9EE),
    bar: Color(0xFFF9F9FB),
    success: Color(0xFF248A3D),
    warning: Color(0xFFC25400),
    warningSoft: Color(0xFFFFF2E5),
  );

  static const dark = XyColors(
    sky: Color(0xFF181A38),
    skyDeep: Color(0xFF0A0B1C),
    onSky: Color(0xFFF5F4FF),
    onSkyMuted: Color(0xFFA9ABD6),
    skyLine: Color(0xFF2E3260),
    star: Color(0xFFFFC542),
    partner: Color(0xFFFF8A7A),
    partnerText: Color(0xFFFF9F92),
    partnerSoft: Color(0xFF3A211F),
    muted: Color(0xFF98989F),
    faint: Color(0xFF5E5E63),
    line: Color(0xFF38383A),
    card: Color(0xFF1C1C1E),
    cardSoft: Color(0xFF2C2C2E),
    fill: Color(0xFF2C2C2E),
    bar: Color(0xFF151517),
    success: Color(0xFF30D158),
    warning: Color(0xFFFF9F0A),
    warningSoft: Color(0xFF3A2A12),
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
const xyCardRadius = 14.0;

/// Prominent buttons.
const xyButtonRadius = 12.0;

ThemeData buildXyTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final xy = dark ? XyColors.dark : XyColors.light;
  final background = dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);
  final ink = dark ? const Color(0xFFF5F5F7) : const Color(0xFF111114);
  final primary = dark ? const Color(0xFF8E8BFF) : const Color(0xFF5856D6);
  const onPrimary = Colors.white;
  final primaryContainer = dark
      ? const Color(0xFF26254F)
      : const Color(0xFFEAEAFB);
  final onPrimaryContainer = dark
      ? const Color(0xFFDCDBFF)
      : const Color(0xFF2E2C8F);
  final error = dark ? const Color(0xFFFF453A) : const Color(0xFFE0352B);
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
    errorContainer: dark ? const Color(0xFF3B1A18) : const Color(0xFFFFECEA),
    onErrorContainer: dark ? const Color(0xFFFFB4AB) : const Color(0xFF8C1D14),
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
    inverseSurface: dark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E),
    onInverseSurface: dark ? const Color(0xFF111114) : const Color(0xFFF5F5F7),
    inversePrimary: dark ? const Color(0xFF5856D6) : const Color(0xFFB9B7FF),
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
  }) => style?.copyWith(
    fontSize: size,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height,
  );
  final text = base.textTheme;
  final textTheme = text
      .copyWith(
        displaySmall: tune(
          text.displaySmall,
          34,
          FontWeight.w700,
          height: 1.2,
          spacing: -0.4,
        ),
        headlineLarge: tune(
          text.headlineLarge,
          34,
          FontWeight.w700,
          height: 1.2,
          spacing: -0.4,
        ),
        headlineMedium: tune(
          text.headlineMedium,
          28,
          FontWeight.w700,
          height: 1.25,
          spacing: -0.3,
        ),
        headlineSmall: tune(
          text.headlineSmall,
          22,
          FontWeight.w700,
          height: 1.3,
          spacing: -0.2,
        ),
        titleLarge: tune(text.titleLarge, 20, FontWeight.w600, height: 1.3),
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

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(xyButtonRadius),
  );
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide.none,
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      disabledBorder: fieldBorder,
      focusedBorder: fieldBorder,
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
        shape: WidgetStatePropertyAll(buttonShape),
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
        shape: WidgetStatePropertyAll(buttonShape),
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
          size: 25,
          color: states.contains(WidgetState.selected) ? primary : xy.muted,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? (dark ? const Color(0xFF30D158) : const Color(0xFF34C759))
            : xy.fill,
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
      backgroundColor: dark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      actionTextColor: dark ? primary : const Color(0xFFB9B7FF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: xy.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: textTheme.titleMedium,
      contentTextStyle: textTheme.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: xy.card,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: xy.faint,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: xy.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: xy.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: xy.muted,
      linearTrackColor: xy.fill,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
      textColor: Colors.white,
    ),
    tooltipTheme: const TooltipThemeData(
      // iOS has no long-press tooltips; the message still labels the control
      // for VoiceOver.
      triggerMode: TooltipTriggerMode.manual,
    ),
  );
}
