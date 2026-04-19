"""
Install the AI Troubleshooting Agent as a Windows Service.
Usage:
    python install_service.py install   - Install the service
    python install_service.py start     - Start the service
    python install_service.py stop      - Stop the service
    python install_service.py remove    - Remove the service
"""
import subprocess
import sys
import os

SERVICE_NAME = "TroubleshootAgent"
DISPLAY_NAME = "AI Troubleshooting Agent"
DESCRIPTION = "Intelligent IT troubleshooting agent for Windows environments"
INSTALL_DIR = os.path.dirname(os.path.abspath(__file__))


def get_python_path():
    return sys.executable


def install():
    python = get_python_path()
    main_script = os.path.join(INSTALL_DIR, "main.py")

    # Use NSSM if available, otherwise use sc.exe with a wrapper
    nssm = os.path.join(INSTALL_DIR, "nssm.exe")
    if os.path.exists(nssm):
        subprocess.run([nssm, "install", SERVICE_NAME, python, main_script], check=True)
        subprocess.run([nssm, "set", SERVICE_NAME, "Description", DESCRIPTION], check=True)
        subprocess.run([nssm, "set", SERVICE_NAME, "AppDirectory", INSTALL_DIR], check=True)
        subprocess.run([nssm, "set", SERVICE_NAME, "Start", "SERVICE_AUTO_START"], check=True)
        print(f"Service '{SERVICE_NAME}' installed via NSSM.")
    else:
        # Create a batch wrapper
        bat_path = os.path.join(INSTALL_DIR, "run_agent.bat")
        with open(bat_path, "w") as f:
            f.write(f'@echo off\ncd /d "{INSTALL_DIR}"\n"{python}" main.py\n')

        cmd = f'sc create {SERVICE_NAME} binPath= "{bat_path}" DisplayName= "{DISPLAY_NAME}" start= auto'
        print(f"Run this command as Administrator:")
        print(f"  {cmd}")
        print()
        print("Or download NSSM (nssm.cc) and place nssm.exe in the install directory,")
        print("then re-run this script for automatic service installation.")
        print()
        print(f"Alternatively, you can just run: python main.py")

        # Create the batch file anyway
        print(f"\nBatch file created at: {bat_path}")
        print("You can also add this to Task Scheduler for auto-start.")


def start():
    subprocess.run(["sc", "start", SERVICE_NAME], check=True)
    print(f"Service '{SERVICE_NAME}' started.")


def stop():
    subprocess.run(["sc", "stop", SERVICE_NAME], check=True)
    print(f"Service '{SERVICE_NAME}' stopped.")


def remove():
    subprocess.run(["sc", "delete", SERVICE_NAME], check=True)
    print(f"Service '{SERVICE_NAME}' removed.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    action = sys.argv[1].lower()
    actions = {"install": install, "start": start, "stop": stop, "remove": remove}

    if action in actions:
        actions[action]()
    else:
        print(f"Unknown action: {action}")
        print(__doc__)
