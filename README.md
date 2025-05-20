# 🍺 Brew Upgrade Tracker

A smart Homebrew helper script that enhances the update and upgrade process by providing detailed information about available package updates.

![image](https://github.com/user-attachments/assets/cf807b0e-0930-4031-8d67-5ada1815fb42)


## 📋 Description

`brew_upgrade_tracker.sh` is a ZSH script that wraps around Homebrew's update and upgrade functionality, providing additional insights and control. It tracks installed packages before and after running `brew update`, shows detailed information about available updates (including package homepages and descriptions), and allows you to decide whether to proceed with the upgrade process.

## 🔧 Prerequisites

- macOS with [Homebrew](https://brew.sh/) installed
- [jq](https://stedolan.github.io/jq/) (JSON processor) - the script will check for this dependency
- ZSH shell (default on modern macOS installations)

## 📥 Installation

1. Clone or download this repository:
   ```
   git clone https://github.com/cicciocanestro/brew-update-tracker.git
   ```
   or download the script directly.

2. Make the script executable:
   ```
   chmod +x brew_upgrade_tracker.sh
   ```

3. Optionally, move the script to a directory in your PATH for easier access:
   ```
   mv brew_upgrade_tracker.sh /usr/local/bin/
   ```

## 🚀 Usage

Simply run the script from your terminal:

```bash
./brew_upgrade_tracker.sh
```

Or if you've added it to your PATH:

```bash
brew_upgrade_tracker.sh
```

## ✨ Features

- 📊 **Comprehensive Package Tracking**: Records and compares installed Homebrew formulae and casks before and after updates
- 🔍 **Detailed Package Information**: Displays homepage links and descriptions for all updated and new packages
- 🆕 **New Package Detection**: Identifies newly available packages in the Homebrew repositories
- ⚙️ **Interactive Upgrade Process**: Asks for confirmation before running `brew upgrade`
- 🎨 **Colorful Output**: Uses color-coded terminal output for better readability
- 🧹 **Clean Operation**: Creates temporary files that are automatically removed upon completion

## 🖥️ Output Notes

- The script uses colored output to distinguish between different types of information:
  - 🟢 Green: Success messages and status information
  - 🔵 Cyan: Process steps and status updates
  - 🟡 Yellow: Prompts and warnings
  - 🔴 Red: Error messages

- The script is interactive and will prompt you to confirm before performing the actual package upgrades, giving you control over when to upgrade your system.

## 🛑 Troubleshooting

If you encounter any issues:

1. Ensure Homebrew is correctly installed and functioning
2. Verify that jq is installed (`brew install jq`)
3. Check that the script has execute permissions

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

