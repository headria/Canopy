/// Public product identity shared by the app, its artwork, and release tools.
/// Storage and signing identifiers are intentionally independent of branding.
public enum ProductBrand {
    public static let name = "Canopy"
    public static let tagline = "Catch it. Keep going."

    public enum Palette {
        public static let paper: UInt32 = 0xF2F6FC
        public static let ink: UInt32 = 0x24374D
        public static let muted: UInt32 = 0x5A6D85
        public static let accent: UInt32 = 0xBDD5F5
        public static let border: UInt32 = 0xCAD7E8
        public static let surface: UInt32 = 0xFCFDFF
        public static let primary: UInt32 = 0x335F93
        public static let iconTop: UInt32 = 0x3F607F
    }
}
