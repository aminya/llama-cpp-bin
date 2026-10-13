# llama.cpp binary packages for Arch Linux

This repository packages the official Linux x86_64 binary archives from
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp). It repackages upstream files and does not
compile llama.cpp. This is a personal package source repository, not an AUR package.

## Package layout

Each channel has one split PKGBUILD. Its CPU core package owns the standard `/usr/bin/llama-*`
commands and common CPU libraries in `/usr/lib/llama.cpp/`. Backend subpackages add their libraries
in that directory and depend on the matching core version. Backend packages conflict with other
backend providers. Stable and prerelease cores also conflict, so only one channel and one accelerator
backend can be active at a time.

Stable package names use `llama-cpp-<variant>-bin`; prerelease backend names use
`llama-cpp-<variant>-prerelease-bin`. The CPU core package names are `llama-cpp-bin` and
`llama-cpp-prerelease-bin`. Supported backends are Vulkan, CUDA 12, CUDA 13, ROCm, OpenVINO, SYCL
FP16, and SYCL FP32. CUDA backends also package upstream's separate CUDA runtime archive, including
`libcudart`, `libcublas`, and `libcublasLt`. The OpenVINO package includes upstream's licensing
directory when present.

The stable `v0.6.0` release does not contain Linux x86_64 binary archives. It publishes a
`nightly-tag.txt` pointer to `b11429`, whose release contains the complete Linux x86_64 binary set.
The updater prefers a release's own CPU archive when available; otherwise, it resolves this pointer
to source binaries for the stable package channel. It keeps `pkgver=0.6.0` and stable package names
while extracting binaries from the `b11429` archives. If the pointer changes without a stable version
change, it increments `pkgrel`. The prerelease channel independently uses the latest release whose
GitHub metadata has `prerelease: true`.

## Build and install

Each channel is one split PKGBUILD. `makepkg` builds its core and backend packages; install the core with at most one backend. The CPU core alone provides CPU-only use.

| Variant   | Stable package            | Prerelease package                   |
| --------- | ------------------------- | ------------------------------------ |
| CPU       | `llama-cpp-bin`           | `llama-cpp-prerelease-bin`           |
| Vulkan    | `llama-cpp-vulkan-bin`    | `llama-cpp-vulkan-prerelease-bin`    |
| CUDA 12   | `llama-cpp-cuda12-bin`    | `llama-cpp-cuda12-prerelease-bin`    |
| CUDA 13   | `llama-cpp-cuda13-bin`    | `llama-cpp-cuda13-prerelease-bin`    |
| ROCm      | `llama-cpp-rocm-bin`      | `llama-cpp-rocm-prerelease-bin`      |
| OpenVINO  | `llama-cpp-openvino-bin`  | `llama-cpp-openvino-prerelease-bin`  |
| SYCL FP16 | `llama-cpp-sycl-fp16-bin` | `llama-cpp-sycl-fp16-prerelease-bin` |
| SYCL FP32 | `llama-cpp-sycl-fp32-bin` | `llama-cpp-sycl-fp32-prerelease-bin` |

Prerelease CUDA 13 example:

```sh
cd packages/prerelease  
makepkg # builds all prerelease variants
sudo pacman -U llama-cpp-prerelease-bin-*.pkg.tar.zst llama-cpp-cuda13-prerelease-bin-*.pkg.tar.zst
```

Stable CUDA 13 example, once upstream publishes the required stable binaries:

```sh
cd packages/stable  
makepkg # builds all prerelease variants
sudo pacman -U llama-cpp-bin-*.pkg.tar.zst llama-cpp-cuda13-bin-*.pkg.tar.zst
```

For another backend, use its package name from the table. CPU-only installs need only the core
package. Split packaging follows the Ollama PKGBUILD convention: `makepkg` fetches the channel's
complete source list while producing its subpackages.

## Update metadata

The GitHub Actions workflow polls upstream every six hours and supports manual dispatch. It resolves
the stable release's `nightly-tag.txt` pointer and checks the prerelease channel independently,
refreshes PKGBUILD versions, official source URLs, SHA256 checksums, and `.SRCINFO`, then opens a pull
request. It does not retain package archives or build/test packages. A channel update is staged only
when its CPU core, all previously published backend assets, and each CUDA runtime asset are available;
a partial upstream upload leaves the prior channel metadata in place.

Run the metadata updater locally with:

```sh
GITHUB_TOKEN=... ./scripts/update-packages.sh
./scripts/generate-srcinfo.sh
```

When GitHub supplies an asset SHA256 digest, the updater uses it. Otherwise it streams the official
asset through `sha256sum` without saving the archive. This repository generates PKGBUILDs and
metadata; publishing built archives in a signed pacman repository is a separate step.

## License

The repository scripts and packaging metadata are MIT-licensed. Packaged llama.cpp binaries and
their upstream license remain the property of the llama.cpp authors.
