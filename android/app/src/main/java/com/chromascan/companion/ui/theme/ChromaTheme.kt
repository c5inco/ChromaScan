package com.chromascan.companion.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chromascan.companion.R

val GoogleSansFlexFamily = FontFamily(
    Font(R.font.google_sans_flex_regular, FontWeight.Normal),
    Font(R.font.google_sans_flex_medium, FontWeight.Medium),
    Font(R.font.google_sans_flex_semibold, FontWeight.SemiBold),
    Font(R.font.google_sans_flex_bold, FontWeight.Bold)
)

/**
 * ChromaScan darkroom palette rendered through Material 3 Expressive tonal surfaces:
 * warm cold-press cream primary, vermilion poppy secondary, optical cyan tertiary,
 * and layered warm darkroom ink containers.
 */
object ChromaPalette {
    val Cream = Color(0xFFF2E0C4)
    val CreamContainer = Color(0xFF473A29)
    val Vermilion = Color(0xFFFA5724)
    val VermilionContainer = Color(0xFF5A2110)
    val OpticalCyan = Color(0xFF38D4F5)
    val Ink = Color(0xFF1A1715)

    // Material 3 layered tonal surface hierarchy (darkroom archival warm charcoal)
    val Background = Color(0xFF12100E)
    val SurfaceLowest = Color(0xFF0E0C0B)
    val SurfaceLow = Color(0xFF191614)
    val Surface = Color(0xFF1D1917)
    val SurfaceHigh = Color(0xFF27221F)
    val SurfaceHighest = Color(0xFF332D29)
    val SurfaceElevated = SurfaceHigh
    val SurfaceVariant = SurfaceHighest

    val Outline = Color(0xFF4E463F)
    val OutlineVariant = Color(0xFF342E29)
    val OnSurface = Color(0xFFF5EFE8)
    val OnSurfaceMuted = Color(0xFFBDB3A8)

    val Success = Color(0xFF34C77B)
    val Warning = Color(0xFFF5A623)
    val Danger = Color(0xFFFF6B63)
    val DangerContainer = Color(0xFF4E1B18)
    val OnDangerContainer = Color(0xFFFFDAD6)
}

private val ChromaExpressiveDarkScheme = darkColorScheme(
    primary = ChromaPalette.Cream,
    onPrimary = ChromaPalette.Ink,
    primaryContainer = ChromaPalette.CreamContainer,
    onPrimaryContainer = ChromaPalette.Cream,
    secondary = ChromaPalette.Vermilion,
    onSecondary = Color.White,
    secondaryContainer = ChromaPalette.VermilionContainer,
    onSecondaryContainer = Color(0xFFFFDBD0),
    tertiary = ChromaPalette.OpticalCyan,
    onTertiary = ChromaPalette.Ink,
    tertiaryContainer = Color(0xFF0E3B46),
    onTertiaryContainer = Color(0xFFC2F0FC),
    background = ChromaPalette.Background,
    onBackground = ChromaPalette.OnSurface,
    surface = ChromaPalette.Surface,
    onSurface = ChromaPalette.OnSurface,
    surfaceVariant = ChromaPalette.SurfaceHighest,
    onSurfaceVariant = ChromaPalette.OnSurfaceMuted,
    surfaceContainerLowest = ChromaPalette.SurfaceLowest,
    surfaceContainerLow = ChromaPalette.SurfaceLow,
    surfaceContainer = ChromaPalette.Surface,
    surfaceContainerHigh = ChromaPalette.SurfaceHigh,
    surfaceContainerHighest = ChromaPalette.SurfaceHighest,
    outline = ChromaPalette.Outline,
    outlineVariant = ChromaPalette.OutlineVariant,
    error = ChromaPalette.Danger,
    onError = Color(0xFF3B0807),
    errorContainer = ChromaPalette.DangerContainer,
    onErrorContainer = ChromaPalette.OnDangerContainer
)

private val ChromaExpressiveShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(18.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(28.dp)
)

private val ChromaExpressiveTypography = Typography(
    displayLarge = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 57.sp,
        lineHeight = 64.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.5).sp
    ),
    displayMedium = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 45.sp,
        lineHeight = 52.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.4).sp
    ),
    displaySmall = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 36.sp,
        lineHeight = 42.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.3).sp
    ),
    headlineLarge = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 32.sp,
        lineHeight = 38.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.3).sp
    ),
    headlineMedium = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 28.sp,
        lineHeight = 34.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.25).sp
    ),
    headlineSmall = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 24.sp,
        lineHeight = 30.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.15).sp
    ),
    titleLarge = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 21.sp,
        lineHeight = 27.sp,
        fontWeight = FontWeight.SemiBold
    ),
    titleMedium = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 16.sp,
        lineHeight = 22.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.05.sp
    ),
    titleSmall = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        fontWeight = FontWeight.SemiBold
    ),
    bodyLarge = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        fontWeight = FontWeight.Normal
    ),
    bodyMedium = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        fontWeight = FontWeight.Normal
    ),
    bodySmall = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        fontWeight = FontWeight.Normal
    ),
    labelLarge = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.1.sp
    ),
    labelMedium = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.3.sp
    ),
    labelSmall = TextStyle(
        fontFamily = GoogleSansFlexFamily,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        fontWeight = FontWeight.Medium,
        letterSpacing = 0.3.sp
    )
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ChromaScanTheme(content: @Composable () -> Unit) {
    MaterialExpressiveTheme(
        colorScheme = ChromaExpressiveDarkScheme,
        motionScheme = MotionScheme.expressive(),
        shapes = ChromaExpressiveShapes,
        typography = ChromaExpressiveTypography,
        content = content
    )
}
