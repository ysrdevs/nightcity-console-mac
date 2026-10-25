module CyberwareEx
import Codeware.Localization.*

public class EnglishPackage extends ModLocalizationPackage {
  protected func DefineTexts() {
    this.Text("UI-CyberwareEx-NotificationRequirements", "Cyberware-EX requires:\\n- TweakXL {tweak_xl_req} or higher\\n- Codeware {codeware_req} or higher\\n\\nDetected TweakXL {tweak_xl_ver} and Codeware {codeware_ver}.\\n\\nPlease update the dependencies to use this mod.");
    this.Text("UI-CyberwareEx-NotificationConflicts", "Cyberware-EX has detected a conflicting mod.\\n\\nThe following mods may cause problems or block the functionality:\\n{conflicts}\\nPlease disable or remove conflicting mods if you wish to use Cyberware-EX.");
  }
}
