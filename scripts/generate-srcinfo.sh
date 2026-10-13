#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
shopt -s nullglob
package_builds=("${repo_root}"/packages/*/PKGBUILD)
(( ${#package_builds[@]} > 0 )) || exit 0
package_dirs=()
for package_build in "${package_builds[@]}"; do
  package_dirs+=("${package_build%/PKGBUILD}")
done

if command -v makepkg >/dev/null 2>&1; then
  for package_dir in "${package_dirs[@]}"; do
    (cd "${package_dir}" && makepkg --printsrcinfo > .SRCINFO)
  done
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'makepkg or Docker is required to regenerate .SRCINFO.\n' >&2
  exit 1
fi

docker run --rm \
  -e "HOST_UID=$(id -u)" \
  -v "${repo_root}:/repo" \
  archlinux:base-devel \
  bash -euo pipefail -c '
    useradd --uid "${HOST_UID}" --create-home srcinfo-builder
    chown -R "${HOST_UID}:${HOST_UID}" /repo/packages
    for package_build in /repo/packages/*/PKGBUILD; do
      [[ -f "${package_build}" ]] || continue
      package_dir="${package_build%/PKGBUILD}"
      su srcinfo-builder -c "cd ${package_dir} && makepkg --printsrcinfo" \
        > "${package_dir}/.SRCINFO"
    done
  '
