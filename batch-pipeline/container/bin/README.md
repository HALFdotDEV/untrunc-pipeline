# Untrunc Binary Directory

Place the compiled untrunc binary here:
- `untrunc-linux-amd64` - For x86_64 AWS Batch jobs

Build with:
```bash
cd ../../../
./build-untrunc.sh
```

Or manually:
```bash
git clone https://github.com/anthwlock/untrunc.git
cd untrunc
make FF_VER=6.0
cp untrunc /path/to/bin/untrunc-linux-amd64
```
