"""Local Efinity runner with explicit DLL search, no persistent environment edits."""
import os,runpy,sys
from pathlib import Path
ROOT=Path(os.environ.get('EFINITY_HOME','D:/Efinity/2026.1'))
for key,relative in {'EFINITY_HOME':'','EFXPT_HOME':'pt','EFXPGM_HOME':'pgm','EFXDBG_HOME':'debugger','EFXIPM_HOME':'ipm','EFXSVF_HOME':'debugger/svf_player','EFXSERDESDBG_HOME':'debugger/serdes_debug_tool'}.items():
 os.environ[key]=(ROOT/relative).as_posix()
os.environ['EFINITY_USER_DIR_INI']=(Path(os.environ['LOCALAPPDATA'])/'efinity/user_dir.ini').as_posix()
os.environ['QT_PLUGIN_PATH']=(ROOT/'bin').as_posix()
os.environ['QT_QPA_PLATFORM_PLUGIN_PATH']=(ROOT/'python311/platforms').as_posix()
os.environ['PATH']=';'.join(str(ROOT/p) for p in ['python311/bin','bin','pgm/bin','scripts'])+';'+os.environ['PATH']
handles=[os.add_dll_directory(str(ROOT/p)) for p in ['bin','python311/bin']]
sys.path.insert(0,str(ROOT/'scripts'))
sys.argv=[str(ROOT/'scripts/efx_run.py')]+sys.argv[1:]
runpy.run_path(str(ROOT/'scripts/efx_run.py'),run_name='__main__')
