import 'package:flutter/material.dart';

/// 접근성 우선 테마: 큰 글씨, 고대비, 큰 터치 영역.
ThemeData ongiTheme() {
  const seed = Color(0xFFE8630A); // 온기 주황 — 따뜻함

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: seed),
    visualDensity: VisualDensity.comfortable,
  );

  // 접근성 스펙(기획설계서 §6): 본문 22sp 이상 — 시스템 글꼴 확대와 중첩 적용된다.
  final textTheme = base.textTheme.copyWith(
    bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 18),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 22),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 24),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 24),
    titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 28),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(fontSize: 30),
  );

  return base.copyWith(
    textTheme: textTheme,
    // 터치 실수를 줄이기 위한 넉넉한 최소 터치 영역.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: base.appBarTheme.copyWith(centerTitle: true),
  );
}
