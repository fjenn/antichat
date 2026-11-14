// M4.T06 step 1 (R-286 AC1): the `create_image` tool contract offered to the chat model when Photo is installed and
// enabled. The harness validates calls against this schema (one repair retry, G-012) and turns a valid call into a
// media job (ImageRequestBuilder → MediaJobQueue). `count` stays 1 in v1 (variants + upscale moved to M11, D-026).
import Foundation

public enum CreateImageTool {
    public static let name = "create_image"
    public static let description = "Create a picture from a text description. Use it whenever the user asks for an image, drawing, photo or illustration."
    public static let aspects = ["1:1", "3:2", "2:3", "16:9", "9:16"]
    public static let modes = ["generate", "variations", "upscale"]

    public static let parametersJSON = #"""
    {"type":"object","required":["prompt"],"properties":{"prompt":{"type":"string","description":"What the picture shows, in detail."},"negative_prompt":{"type":"string","description":"What the picture must not show."},"aspect":{"type":"string","enum":["1:1","3:2","2:3","16:9","9:16"],"default":"1:1"},"count":{"type":"integer","minimum":1,"maximum":8,"default":1},"style":{"type":"string","description":"A visual style, e.g. watercolor or photo."},"seed":{"type":"integer"},"mode":{"type":"string","enum":["generate","variations","upscale"],"default":"generate"},"source_image_id":{"type":"string","description":"The picture to vary or upscale."}}}
    """#
}
