# Untrunc Binary Directory

Place the compiled untrunc binary here:
- `untrunc-arm64` - For ARM64 Linux (Apple Silicon Mac in Docker)

Build with:
```bash
cd ../
./build-untrunc.sh
```

Or manually on an ARM64 Linux machine:
```bash
git clone https://github.com/anthwlock/untrunc.git
cd untrunc
make FF_VER=6.0
cp untrunc /path/to/bin/untrunc-arm64
```
