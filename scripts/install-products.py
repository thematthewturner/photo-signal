#!/usr/bin/env python3
"""Install reviewed local builds. Optional per-user login startup; never starts paid indexing."""
import argparse, os, plistlib, shutil, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LABEL='local.photosignal.indexer'
def launch_plist(app):
    base=Path.home()/'Library/Application Support/PhotoSignal'
    return dict(Label=LABEL,ProgramArguments=[str(app/'Contents/MacOS/PhotoSignal')],RunAtLoad=True,
                KeepAlive={'SuccessfulExit':False},ThrottleInterval=60,ProcessType='Background',
                LimitLoadToSessionType='Aqua',StandardOutPath=str(base/'history/agent.log'),StandardErrorPath=str(base/'history/agent-error.log'))
def main():
    p=argparse.ArgumentParser();p.add_argument('--login',action='store_true');p.add_argument('--remove-login',action='store_true');p.add_argument('--login-only',action='store_true');a=p.parse_args()
    plist=Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    domain=f'gui/{os.getuid()}'
    apps=Path.home()/'Applications'
    processes=subprocess.check_output(['ps','-axo','command='],text=True).splitlines()
    names=['Photo Signal','Photo Signal Indexer'] if not a.remove_login else ['Photo Signal Indexer']
    if any(line.startswith(str(apps/(name+'.app')/'Contents/MacOS/PhotoSignal')) for name in names for line in processes):
        raise SystemExit('Quit the installed products before installing or changing login startup. Indexer Quit drains active requests.')
    if a.remove_login:
        subprocess.run(['launchctl','bootout',f'{domain}/{LABEL}'],capture_output=True)
        plist.unlink(missing_ok=True);print('Login startup removed. Photo catalog preserved.');return
    apps=Path.home()/'Applications';apps.mkdir(exist_ok=True)
    for name in ([] if a.login_only else ['Photo Signal','Photo Signal Indexer']):
        src=ROOT/'build/products'/f'{name}.app'
        dst=apps/src.name; staged=apps/(src.name+'.installing');backup=apps/(src.name+'.previous')
        if staged.exists():shutil.rmtree(staged)
        shutil.copytree(src,staged,copy_function=shutil.copy)
        # FileProvider may decorate build files after signing. Strip metadata on the local staged copy, then verify its original signature.
        subprocess.run(['xattr','-cr',str(staged)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(staged)],check=True)
        if backup.exists():shutil.rmtree(backup)
        if dst.exists():dst.rename(backup)
        staged.rename(dst)
        print('Installed',dst)
    if a.login or a.login_only:
        base=Path.home()/'Library/Application Support/PhotoSignal/history';base.mkdir(parents=True,exist_ok=True,mode=0o700)
        plist.parent.mkdir(parents=True,exist_ok=True)
        plist.write_bytes(plistlib.dumps(launch_plist(apps/'Photo Signal Indexer.app')));plist.chmod(0o600)
        subprocess.run(['launchctl','bootout',f'{domain}/{LABEL}'],capture_output=True)
        subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
        print('Login startup installed. A new installation remains paused until Watch latest is selected.')
if __name__=='__main__':main()
