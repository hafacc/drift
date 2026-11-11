package cc.hafa.drift

/**
 * Filter-alert reset instructions. The AC's local protocol can only read the alert, not
 * clear it, so this has to be a physical action on the unit itself — and there's no
 * reliable way to resolve which of Midea's control-panel families a given unit uses from
 * what the LAN protocol exposes (its serial number carries no model info, and the one
 * cloud field that does — `productModel` — isn't something this app fetches). Rather than
 * guess, this lists the real, manual-sourced procedures for the common families so the
 * user can match their own unit rather than be told to go check a manual themselves.
 */
object FilterResetGuide {
    const val INSTRUCTIONS =
        "Mini-split (remote): press LED 4×, or Manual Control 3×\n" +
            "Wired wall controller: press & hold left button 3s\n" +
            "Window unit: press & hold Swing / Eco / Filter 3s\n\n" +
            "Check your manual if none of these clear it."
}
