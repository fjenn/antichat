// M4.T06 step 1 (R-286 AC1): the `edit_image` tool contract — change an existing picture by text (M4.T13), with an
// optional mask (inpaint / outpaint). Same validation and job path as `create_image`.
import Foundation

public enum EditImageTool {
    public static let name = "edit_image"
    public static let description = "Change an existing picture as described (edit it, or fill a masked area)."
    public static let modes = ["edit", "inpaint", "outpaint"]
    /// M4.T13 (model-matrix §2.2): `quick` = the create model (FLUX.2-klein img2img), the default on every tier;
    /// `best` = Qwen-Image-Edit where installed (T3+), picked by the user (the viewer's Best quality toggle) for one
    /// turn (`TurnContext.imageEditBest`); the tool schema stays R-286's (no extra field).
    /// The `PhotoModelProviding.modelSet(for:)` key of a best-quality edit.
    public static let bestModelKey = "edit_image.best"

    public static let parametersJSON = #"""
    {"type":"object","required":["prompt","source_image_id"],"properties":{"prompt":{"type":"string","description":"The change to make."},"negative_prompt":{"type":"string"},"source_image_id":{"type":"string","description":"The picture to change."},"mask_id":{"type":"string","description":"The area to change (inpaint / outpaint)."},"aspect":{"type":"string","enum":["1:1","3:2","2:3","16:9","9:16"]},"seed":{"type":"integer"},"mode":{"type":"string","enum":["edit","inpaint","outpaint"],"default":"edit"}}}
    """#
}
