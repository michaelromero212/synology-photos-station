import CoreImage
import Foundation

// A small synthetic HDR picture: a gradient whose brightest part goes past
// SDR white, written the way an iPhone writes one, SDR base plus gain map.
let size = CGRect(x: 0, y: 0, width: 128, height: 96)
let gradient = CIFilter(name: "CILinearGradient", parameters: [
    "inputPoint0": CIVector(x: 0, y: 0),
    "inputPoint1": CIVector(x: 128, y: 96),
    "inputColor0": CIColor(red: 0.1, green: 0.3, blue: 0.8),
    "inputColor1": CIColor(red: 4.0, green: 3.5, blue: 2.5,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)!,
])!.outputImage!.cropped(to: size)
let hdr = gradient
let sdr = gradient.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0])
let context = CIContext()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try context.writeHEIFRepresentation(
    of: sdr, to: url, format: .RGBA8,
    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
    options: [CIImageRepresentationOption.hdrImage: hdr]
)
print("wrote \(url.path)")
