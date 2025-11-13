# 🎙️ Scribe - Start Here

## The Problem You Encountered

You ran `python3 test_setup.py` and got errors about missing modules. This is because Python packages are installed in a **virtual environment** (`venv/` folder), not globally on your system.

## Understanding Virtual Environments

Think of a virtual environment like a separate Python installation just for this project:
- ✅ Keeps this project's packages separate from your system Python
- ✅ Prevents version conflicts with other projects
- ✅ Makes the project portable and reproducible

**The key**: You must "activate" the virtual environment before running any Python scripts.

## How to Use This App - 3 Simple Steps

### Step 1: Install (One Time Only)

```bash
./setup.sh
```

This creates the virtual environment and installs everything you need.

### Step 2: Test Installation

```bash
./test.sh
```

This activates the virtual environment and runs the tests. You should see all ✅ checkmarks.

### Step 3: Run the App

```bash
./run.sh
```

This activates the virtual environment and launches the app.

## Why Your Command Failed

❌ **What you did:**
```bash
python3 test_setup.py
```

This uses your system Python, which doesn't have the packages.

✅ **What works:**
```bash
source venv/bin/activate  # Activate the virtual environment first
python test_setup.py      # Now Python can find the packages
```

Or just use the wrapper script:
```bash
./test.sh  # Does both steps for you
```

## Quick Reference

| Command | What It Does |
|---------|-------------|
| `./setup.sh` | Install everything (run once) |
| `./test.sh` | Verify installation works |
| `./run.sh` | Start the app |

## Manual Mode (If You Prefer)

If you want to run commands manually:

1. **Always activate the virtual environment first:**
   ```bash
   source venv/bin/activate
   ```

2. **Your terminal prompt will change to show `(venv)`:**
   ```
   (venv) user@computer scribe %
   ```

3. **Now you can run Python commands:**
   ```bash
   python test_setup.py  # ✅ Works!
   python main.py        # ✅ Works!
   ```

4. **When done, deactivate:**
   ```bash
   deactivate
   ```

## Troubleshooting

### "Permission denied" when running scripts
```bash
chmod +x setup.sh run.sh test.sh
```

### "No such file or directory: venv/"
You need to run `./setup.sh` first to create the virtual environment.

### Still getting "No module named" errors
Make sure you see `(venv)` in your terminal prompt before running Python commands.

### SSL Certificate Errors (Corporate Networks)
If you see SSL/certificate errors when downloading the model:
```bash
source venv/bin/activate
python download_model.py
```

This will download the model with SSL verification disabled. See `TROUBLESHOOTING.md` for more details.

## Next Steps

1. Run `./test.sh` to verify everything is working
2. Run `./run.sh` to launch the app
3. Click "Start Recording" and start talking!
4. Read `QUICKSTART.md` for detailed usage instructions

## Files Explained

- `setup.sh` - Installs everything (run once)
- `run.sh` - Convenient script to start the app
- `test.sh` - Convenient script to test installation
- `venv/` - Virtual environment folder (contains all packages)
- `main.py` - The actual application
- `test_setup.py` - Installation verification script

Happy transcribing! 🎉
