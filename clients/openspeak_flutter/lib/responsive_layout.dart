import 'dart:math' as math;

const mobileWebBreakpoint = 720.0;

bool useMobileWebLayout({required bool isWeb, required double width}) =>
    isWeb && width < mobileWebBreakpoint;

double? messageListCacheExtent({required bool isWeb, required double width}) =>
    useMobileWebLayout(isWeb: isWeb, width: width) ? null : 900;

int? imagePreviewCacheWidth({
  required bool isWeb,
  required double viewportWidth,
  required double sourceWidth,
  required double displayWidth,
  required double devicePixelRatio,
}) {
  if (!useMobileWebLayout(isWeb: isWeb, width: viewportWidth)) return null;
  return math.max(
    1,
    math.min(sourceWidth, displayWidth * devicePixelRatio).round(),
  );
}
