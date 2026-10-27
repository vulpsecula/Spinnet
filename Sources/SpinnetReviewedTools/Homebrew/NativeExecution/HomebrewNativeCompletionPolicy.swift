import SpinnetCore
import Foundation

/// Source-bound completion adapter for the two reviewed language-pack templates.
/// Their prerequisite branches return zero upstream even when no installation
/// occurred. Only this exact immutable template receives a manual outcome.
public enum HomebrewNativeCompletionPolicy {
    private static let languagePack = #"""
#!/bin/bash
pathOfApp=$(mdfind "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == 'LibreOffice.app'" -onlyin '/__SPINNET_GENERATED_APPDIR__')
if [[ $(mdls --raw --name kMDItemFSName --name kMDItemVersion "$pathOfApp" | xargs -0) == "LibreOffice.app __VERSION__"* ]]
then
  #Test if the .app have quarantine attribute, or if they are already launched once.
  if [[ $(xattr -l "$pathOfApp") != *'com.apple.quarantine'* || $(xattr -p com.apple.quarantine "$pathOfApp") != '0181;'* ]]
  then
    echo "Silent installation has started, you didn't need to use the .app"
    echo "Add language pack support for $pathOfApp"
    /usr/bin/tar -C "$pathOfApp" -xjf "/__SPINNET_GENERATED_PREFIX__/Caskroom/__TOKEN__/__VERSION__/LibreOffice Language Pack.app/Contents/Resources/tarball.tar.bz2" && touch "$pathOfApp"
  else
    echo "You need to run $pathOfApp once before you can silently install language pack"
  fi
else
  echo 'Silent installation cannot match the prerequisite'
  echo "To complete the installation of Cask __TOKEN__, you must also run the installer at:"
  echo "/__SPINNET_GENERATED_PREFIX__/Caskroom/__TOKEN__/__VERSION__/LibreOffice Language Pack.app"
fi
"""# + "\n"
    public static func hasManualOutcome(_ cask: HomebrewPrivilegePlan.Cask) -> Bool {
        if !(cask.manualInstallers ?? []).isEmpty { return true }
        return (cask.nativeScripts ?? []).contains { hasManualOutcome($0, cask: cask) }
    }
    public static func hasManualOutcome(_ script: HomebrewPrivilegePlan.NativeScript, cask: HomebrewPrivilegePlan.Cask) -> Bool {
        guard let proof = cask.sourceProof else { return false }
        let token = String(cask.name.split(separator: "/").last ?? "")
            guard script.phase == .install, let body = script.generatedContent else { return false }
            var neutral = body
            for (actual, marker) in [(proof.configuration.prefix.path, HomebrewNativeGeneratedScript.prefixMarker),
                                     (proof.configuration.appDirectory.path, HomebrewNativeGeneratedScript.appDirectoryMarker)] {
                neutral = neutral.replacingOccurrences(of: actual, with: marker)
            }
            return adapt(neutral, token: token, version: cask.version) != nil
    }
    public static func adapt(_ body: String, token: String, version: String) -> String? {
        guard ["libreoffice-language-pack", "libreoffice-still-language-pack"].contains(token),
              !version.isEmpty, version.utf8.count <= 64,
              version.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || $0 == "." }) else { return nil }
        var expected = languagePack.replacingOccurrences(of: "__TOKEN__", with: token).replacingOccurrences(of: "__VERSION__", with: version)
        if token == "libreoffice-still-language-pack" {
            expected = expected.replacingOccurrences(of: " -onlyin '/__SPINNET_GENERATED_APPDIR__'", with: "")
        }
        guard body == expected else { return nil }
        return body.replacingOccurrences(of: "    echo \"You need to run $pathOfApp once before you can silently install language pack\"\n", with: "    echo \"You need to run $pathOfApp once before you can silently install language pack\"\n    exit 78\n")
            .replacingOccurrences(of: "  echo \"/__SPINNET_GENERATED_PREFIX__/Caskroom/" + token + "/" + version + "/LibreOffice Language Pack.app\"\n", with: "  echo \"/__SPINNET_GENERATED_PREFIX__/Caskroom/" + token + "/" + version + "/LibreOffice Language Pack.app\"\n  exit 78\n")
    }
}
