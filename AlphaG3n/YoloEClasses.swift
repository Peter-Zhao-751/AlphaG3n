//
//  YoloEClasses.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//
//  Static info about the YOLOE-26L segmentation model's output classes.
//  The model emits an integer class id per detection; the names and
//  crop-padding overrides below are all keyed off that id.

import CoreGraphics

/// Class id → name and per-class capture-time settings for the YOLOE-26L model.
///
/// The class list and id order is baked into the .mlpackage at export time
/// (`Data/com.apple.CoreML/model.mlmodel` carries the name dict). Keep this
/// table in sync with whatever prompt list the model was exported with —
/// adding new classes to the model means adding entries here.
enum YoloEClasses {

    /// Class names indexed by the integer id the model emits. Used by the
    /// capture path to look up per-class behavior and by debug overlays.
    static let names: [String] = [
        // screens / devices                      (ids 0–5)
        "cell phone", "laptop", "tablet",
        "computer monitor", "television", "e-reader",
        // printed material                       (ids 6–23)
        "book", "magazine", "newspaper", "notebook", "document", "paper",
        "letter", "envelope", "receipt", "ticket", "menu", "flyer",
        "brochure", "poster", "map", "calendar", "business card", "sticky note",
        // signage                                (ids 24–32)
        "street sign", "traffic sign", "stop sign", "billboard", "banner",
        "license plate", "exit sign", "nameplate", "price tag",
        // packaging / containers                 (ids 33–43)
        "bottle", "can", "jar", "box", "cardboard box", "food packaging",
        "cereal box", "medicine bottle", "shopping bag", "coffee cup", "carton",
        // wearables / branded                    (ids 44–48)
        "t-shirt", "hat", "jersey", "badge", "lanyard",
        // money / cards                          (ids 49–53)
        "banknote", "credit card", "id card", "passport", "coin",
        // other                                  (ids 54–57)
        "keyboard", "whiteboard", "mug", "clock",
    ]

    /// Fractional growth applied to a detection's quad before perspective
    /// correction when the class has no override below. 0.10 means the crop
    /// region is 10% wider and 10% taller than the raw mask quad (5% on each
    /// side), scaled about the quad's centroid so its shape is preserved.
    static let defaultCropPadding: CGFloat = 0.10

    /// Per-class crop padding. Every class has an explicit entry so tuning
    /// one class doesn't require figuring out what the fallback is doing.
    /// Bigger numbers = looser crop. Anything not in the table still falls
    /// back to `defaultCropPadding` (e.g. unknown ids from a re-export).
    private static let cropPaddingOverrides: [Int: CGFloat] = [
        // screens / devices
        0:  0.05,  // cell phone
        1:  0.05,  // laptop
        2:  0.05,  // tablet
        3:  0.05,  // computer monitor
        4:  0.05,  // television
        5:  0.05,  // e-reader
        // printed material
        6:  0.05,  // book
        7:  0.05,  // magazine
        8:  0.05,  // newspaper
        9:  0.05,  // notebook
        10: 0.05,  // document
        11: 0.05,  // paper
        12: 0.05,  // letter
        13: 0.05,  // envelope
        14: 0.05,  // receipt
        15: 0.05,  // ticket
        16: 0.05,  // menu
        17: 0.05,  // flyer
        18: 0.05,  // brochure
        19: 0.05,  // poster
        20: 0.05,  // map
        21: 0.05,  // calendar
        22: 0.05,  // business card
        23: 0.05,  // sticky note
        // signage
        24: 0.05,  // street sign
        25: 0.05,  // traffic sign
        26: 0.05,  // stop sign
        27: 0.05,  // billboard
        28: 0.05,  // banner
        29: 0.05,  // license plate
        30: 0.05,  // exit sign
        31: 0.05,  // nameplate
        32: 0.05,  // price tag
        // packaging / containers
        33: 0.30,  // bottle
        34: 0.30,  // can
        35: 0.05,  // jar
        36: 0.05,  // box
        37: 0.05,  // cardboard box
        38: 0.05,  // food packaging
        39: 0.05,  // cereal box
        40: 0.05,  // medicine bottle
        41: 0.05,  // shopping bag
        42: 0.05,  // coffee cup
        43: 0.05,  // carton
        // wearables / branded
        44: 0.05,  // t-shirt
        45: 0.05,  // hat
        46: 0.05,  // jersey
        47: 0.05,  // badge
        48: 0.05,  // lanyard
        // money / cards
        49: 0.05,  // banknote
        50: 0.05,  // credit card
        51: 0.05,  // id card
        52: 0.05,  // passport
        53: 0.05,  // coin
        // other
        54: 0.05,  // keyboard
        55: 0.05,  // whiteboard
        56: 0.05,  // mug
        57: 0.05,  // clock
    ]

    /// Returns the class name for `classId`, or nil if the id is outside the
    /// known range (e.g. a model export added new classes without this table
    /// being updated).
    static func name(for classId: Int) -> String? {
        guard names.indices.contains(classId) else { return nil }
        return names[classId]
    }

    /// Crop padding to apply for a given class id. Out-of-range ids and
    /// classes without an explicit override both fall back to
    /// `defaultCropPadding`.
    static func cropPadding(for classId: Int?) -> CGFloat {
        guard let classId else { return defaultCropPadding }
        return cropPaddingOverrides[classId] ?? defaultCropPadding
    }
}
