package com.chromascan.companion.ui.theme

import androidx.annotation.DrawableRes
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource

/**
 * Renders an official Material Symbols Rounded vector drawable (`res/drawable/ms_*.xml`).
 */
@Composable
fun MaterialSymbol(
    @DrawableRes iconRes: Int,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    tint: Color = LocalContentColor.current
) {
    Icon(
        painter = painterResource(id = iconRes),
        contentDescription = contentDescription,
        modifier = modifier,
        tint = tint
    )
}
