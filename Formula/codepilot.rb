# Homebrew Cask Formula Template for CodePilot
# Publish in a tap repo (e.g. `homebrew-tap/Casks/codepilot.rb`) and install via:
#   brew install --cask <your-user>/tap/codepilot
#
# Auto-update Roadmap (Sparkle 2):
#   Once Developer ID notarization is enabled, embed Sparkle.framework with EdDSA
#   SUPublicEDKey in Resources/Info.plist and host appcast.xml on GitHub Releases.

cask "codepilot" do
  version "0.4.0"
  sha256 :no_check # Replace with SHA256SUMS value from GitHub Release

  url "https://github.com/Yates411/CodePilot/releases/download/v#{version}/CodePilot-v#{version}-arm64.zip"
  name "CodePilot"
  desc "Native macOS Notch & Menu Bar hub + smart keep-awake for AI coding agents"
  homepage "https://github.com/Yates411/CodePilot"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "CodePilot.app"

  zap trash: [
    "~/Library/Preferences/com.codepilot.app.plist",
    "~/.codepilot",
  ]
end
