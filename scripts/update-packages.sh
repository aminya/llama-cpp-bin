#!/usr/bin/env bash
set -Eeuo pipefail

readonly upstream_api='https://api.github.com/repos/ggml-org/llama.cpp'
readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly package_root="${repo_root}/packages"
readonly split_template="${repo_root}/templates/split-PKGBUILD.in"

mkdir -p "${package_root}"
readonly stage_root="$(mktemp -d "${package_root}/.update.XXXXXX")"
trap 'rm -rf -- "${stage_root}"' EXIT

readonly variants=(vulkan cuda12 cuda13 rocm openvino sycl-fp16 sycl-fp32)
github_headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  github_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

api_json() {
  curl --fail --location --silent --show-error "${github_headers[@]}" "$1"
}

stable_release="$(api_json "${upstream_api}/releases/latest" | jq -ce '
  {tag_name, prerelease, assets: [.assets[] | {name, browser_download_url, digest}]}
')"
nightly_tag_asset="$(jq -c '[.assets[] | select(.name == "nightly-tag.txt")][0] // null' \
  <<< "${stable_release}")"
stable_binary_release=''
stable_asset_tag=''
stable_release_tag="$(jq -er '.tag_name' <<< "${stable_release}")"
stable_cpu_asset_name="llama-${stable_release_tag}-bin-ubuntu-x64.tar.gz"
stable_has_cpu="$(jq -r --arg name "${stable_cpu_asset_name}" \
  '[.assets[] | select(.name == $name)] | length' <<< "${stable_release}")"
if (( stable_has_cpu > 0 )); then
  stable_binary_release="${stable_release}"
  stable_asset_tag="${stable_release_tag}"
elif [[ "${nightly_tag_asset}" == null ]]; then
  printf 'Stable release %s has no Linux x86_64 CPU asset or nightly-tag.txt; retaining any existing stable package base.\n' \
    "${stable_release_tag}"
else
  nightly_tag_url="$(jq -er '.browser_download_url' <<< "${nightly_tag_asset}")"
  stable_asset_tag="$(curl --fail --location --silent --show-error "${nightly_tag_url}" | tr -d '\r\n')"
  if [[ ! "${stable_asset_tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'Stable release nightly-tag.txt contains an invalid tag: %q\n' \
      "${stable_asset_tag}" >&2
  else
    stable_binary_release="$(api_json "${upstream_api}/releases/tags/${stable_asset_tag}" | jq -c '
      select(.prerelease == true and .draft == false)
      | {tag_name, prerelease, assets: [.assets[] | {name, browser_download_url, digest}]}
    ')"
    if [[ -z "${stable_binary_release}" ]]; then
      printf 'Stable release points to %s, but that is not a published prerelease; retaining any existing stable package base.\n' \
        "${stable_asset_tag}"
    fi
  fi
fi
prerelease_release="$(api_json "${upstream_api}/releases?per_page=100" | jq -c '
  map(select(.prerelease == true and .draft == false))
  | sort_by(.published_at)
  | last
  | if . == null then null else
      {tag_name, prerelease, assets: [.assets[] | {name, browser_download_url, digest}]}
    end
')"

asset_for() {
  local release_json="$1"
  local exact_name="$2"
  local name_prefix="$3"

  jq -c --arg exact "${exact_name}" --arg prefix "${name_prefix}" '
    [ .assets[] | select(
        if $exact != "" then .name == $exact
        else (.name | startswith($prefix) and endswith("-x64.tar.gz"))
        end
      ) ]
    | if length == 0 then null else
        sort_by([.name | scan("[0-9]+") | tonumber]) | last
      end
    | if . == null then null else
        {name, url: .browser_download_url,
         sha256: ((.digest // "") | sub("^sha256:"; ""))}
      end
  ' <<< "${release_json}"
}

asset_sha256() {
  local asset_json="$1"
  local digest url
  digest="$(jq -r '.sha256' <<< "${asset_json}")"
  if [[ -n "${digest}" ]]; then
    printf '%s' "${digest}"
    return
  fi

  url="$(jq -r '.url' <<< "${asset_json}")"
  curl --fail --location --silent --show-error "${url}" | sha256sum | cut -d' ' -f1
}

select_variant_asset() {
  local release_json="$1"
  local tag="$2"
  local variant="$3"
  local exact='' prefix=''

  case "${variant}" in
    cpu) exact="llama-${tag}-bin-ubuntu-x64.tar.gz" ;;
    vulkan) exact="llama-${tag}-bin-ubuntu-vulkan-x64.tar.gz" ;;
    cuda12) prefix="llama-${tag}-bin-ubuntu-cuda-12." ;;
    cuda13) prefix="llama-${tag}-bin-ubuntu-cuda-13." ;;
    rocm) prefix="llama-${tag}-bin-ubuntu-rocm-" ;;
    openvino) prefix="llama-${tag}-bin-ubuntu-openvino-" ;;
    sycl-fp16) exact="llama-${tag}-bin-ubuntu-sycl-fp16-x64.tar.gz" ;;
    sycl-fp32) exact="llama-${tag}-bin-ubuntu-sycl-fp32-x64.tar.gz" ;;
    *) printf 'Unknown package variant: %s\n' "${variant}" >&2; return 2 ;;
  esac

  asset_for "${release_json}" "${exact}" "${prefix}"
}

select_cudart_asset() {
  local release_json="$1"
  local tag="$2"
  local variant="$3"
  local prefix
  case "${variant}" in
    cuda12) prefix="cudart-llama-${tag}-bin-ubuntu-cuda-12." ;;
    cuda13) prefix="cudart-llama-${tag}-bin-ubuntu-cuda-13." ;;
    *) return 2 ;;
  esac
  asset_for "${release_json}" '' "${prefix}"
}

render_pkgbuild() {
  local template="$1"
  local output="$2"
  local content token
  content="$(<"${template}")"
  for token in "${!template_values[@]}"; do
    content="${content//"@${token}@"/"${template_values[${token}]}"}"
  done
  while [[ "${content}" == *$'\n' ]]; do
    content="${content%$'\n'}"
  done
  printf '%s\n' "${content}" > "${output}"
}

channel_has_variant() {
  local sought="$1"
  local candidate
  for candidate in "${expected_variants[@]}"; do
    [[ "${candidate}" == "${sought}" ]] && return 0
  done
  return 1
}

backend_display_name() {
  case "$1" in
    vulkan) printf 'Vulkan' ;;
    cuda12) printf 'CUDA 12' ;;
    cuda13) printf 'CUDA 13' ;;
    rocm) printf 'ROCm' ;;
    openvino) printf 'OpenVINO' ;;
    sycl-fp16) printf 'SYCL FP16' ;;
    sycl-fp32) printf 'SYCL FP32' ;;
    *) printf '%s' "$1" ;;
  esac
}

backend_package_name() {
  local variant="$1"
  local channel="$2"
  local suffix=''
  [[ "${channel}" == prerelease ]] && suffix='-prerelease'
  printf 'llama-cpp-%s%s-bin' "${variant}" "${suffix}"
}

backend_package_fields() {
  local variant="$1"
  case "${variant}" in
    vulkan)
      backend_depends="  'vulkan-driver'"$'\n'
      backend_optdepends=$'  \'vulkan-intel: Intel GPU acceleration\'\n  \'vulkan-radeon: AMD GPU acceleration\'\n'
      plugin='vulkan'
      ;;
    cuda12|cuda13)
      backend_depends="  'nvidia-libgl'"$'\n'
      backend_optdepends=''
      plugin='cuda'
      ;;
    rocm)
      backend_depends="  'hip-runtime-amd'"$'\n  \'hipblas\'\n  \'rocblas\'\n'
      backend_optdepends=''
      plugin='hip'
      ;;
    openvino)
      backend_depends=''
      backend_optdepends="  'intel-compute-runtime: Intel GPU acceleration'"$'\n'
      plugin='openvino'
      ;;
    sycl-fp16|sycl-fp32)
      backend_depends="  'intel-oneapi-compiler-dpcpp-cpp-runtime'"$'\n'
      backend_optdepends="  'intel-compute-runtime: Intel GPU acceleration'"$'\n'
      plugin='sycl'
      ;;
  esac
}

stage_channel() {
  local package_release="$1"
  local channel="$2"
  local binaries_release="$3"
  local package_tag asset_tag pkgver pkgrel channel_label core_pkgname core_local core_url core_sha core_name channel_conflicts
  local previous_pkgver previous_pkgrel previous_asset_tag
  local core_asset marker expected_csv variant asset_json asset_name asset_url asset_sha
  local extra_asset extra_name extra_root extra_url extra_sha local_name pkgname display plugin
  local core_optdepends source_lines checksum_lines noextract_lines backend_names backend_variants
  local backend_archive_map backend_plugin_map cudart_archive_map cudart_root_map package_functions
  local optdepends_block conflicts conflict_candidate capability
  local stage_channel_dir destination
  local -a expected_variants=() available_variants=()
  local -A variant_assets=() variant_cudart_assets=() variant_shas=() cudart_shas=()

  [[ -n "${package_release}" && "${package_release}" != null \
    && -n "${binaries_release}" && "${binaries_release}" != null ]] || return 0
  package_tag="$(jq -er '.tag_name' <<< "${package_release}")"
  asset_tag="$(jq -er '.tag_name' <<< "${binaries_release}")"
  [[ -n "${package_tag}" && -n "${asset_tag}" ]] || return 0
  pkgver="${package_tag#v}"
  pkgver="${pkgver//-/_}"

  if [[ "${channel}" == prerelease ]]; then
    channel_label='prerelease'
    core_pkgname='llama-cpp-prerelease-bin'
    channel_conflicts="  'llama-cpp-bin'"$'\n'
  else
    channel_label='stable'
    core_pkgname='llama-cpp-bin'
    channel_conflicts="  'llama-cpp-prerelease-bin'"$'\n'
  fi

  destination="${package_root}/${channel}"
  marker="${destination}/.upstream-generated"
  pkgrel=1
  if [[ -f "${marker}" ]]; then
    expected_csv="$(sed -n 's/^variants=//p' "${marker}")"
    if [[ -n "${expected_csv}" ]]; then
      IFS=',' read -r -a expected_variants <<< "${expected_csv}"
    fi
    previous_pkgver="$(sed -n 's/^pkgver=//p' "${marker}")"
    previous_pkgrel="$(sed -n 's/^pkgrel=//p' "${marker}")"
    previous_asset_tag="$(sed -n 's/^asset_tag=//p' "${marker}")"
    if [[ "${previous_pkgver}" == "${pkgver}" && "${previous_asset_tag}" == "${asset_tag}" \
      && "${previous_pkgrel}" =~ ^[0-9]+$ ]]; then
      pkgrel="${previous_pkgrel}"
    elif [[ "${previous_pkgver}" == "${pkgver}" && -n "${previous_asset_tag}" \
      && "${previous_asset_tag}" != "${asset_tag}" && "${previous_pkgrel}" =~ ^[0-9]+$ ]]; then
      pkgrel=$((previous_pkgrel + 1))
    fi
  fi

  core_asset="$(select_variant_asset "${binaries_release}" "${asset_tag}" cpu)"
  if [[ "${core_asset}" == null ]]; then
    printf 'No CPU core asset for binary tag %s; retaining any existing %s package base.\n' \
      "${asset_tag}" "${channel}"
    return 0
  fi

  for variant in "${variants[@]}"; do
    asset_json="$(select_variant_asset "${binaries_release}" "${asset_tag}" "${variant}")"
    if [[ "${asset_json}" == null ]]; then
      if channel_has_variant "${variant}"; then
        printf 'Missing expected %s asset in %s; retaining the previous %s package base.\n' \
          "${variant}" "${asset_tag}" "${channel}"
        return 0
      fi
      continue
    fi

    variant_assets["${variant}"]="${asset_json}"
    if [[ "${variant}" == cuda12 || "${variant}" == cuda13 ]]; then
      extra_asset="$(select_cudart_asset "${binaries_release}" "${asset_tag}" "${variant}")"
      if [[ "${extra_asset}" == null ]]; then
        unset "variant_assets[${variant}]"
        if channel_has_variant "${variant}"; then
          printf 'Missing expected %s runtime asset in %s; retaining the previous %s package base.\n' \
            "${variant}" "${asset_tag}" "${channel}"
          return 0
        fi
        printf 'Missing %s runtime asset in %s; skipping the new %s backend.\n' \
          "${variant}" "${asset_tag}" "${channel}"
        continue
      fi
      variant_cudart_assets["${variant}"]="${extra_asset}"
    fi
    available_variants+=("${variant}")
  done

  core_name="$(jq -er '.name' <<< "${core_asset}")"
  core_url="$(jq -er '.url' <<< "${core_asset}")"
  core_sha="$(asset_sha256 "${core_asset}")"
  core_local="core-${core_name}"

  for variant in "${available_variants[@]}"; do
    variant_shas["${variant}"]="$(asset_sha256 "${variant_assets[${variant}]}")"
    if [[ "${variant}" == cuda12 || "${variant}" == cuda13 ]]; then
      cudart_shas["${variant}"]="$(asset_sha256 "${variant_cudart_assets[${variant}]}")"
    fi
  done

  stage_channel_dir="${stage_root}/${channel}"
  mkdir -p "${stage_channel_dir}"
  core_optdepends=''
  source_lines=''
  checksum_lines=''
  noextract_lines=''
  backend_names=''
  backend_variants=''
  backend_archive_map=''
  backend_plugin_map=''
  cudart_archive_map=''
  cudart_root_map=''
  package_functions=''

  for variant in "${available_variants[@]}"; do
    pkgname="$(backend_package_name "${variant}" "${channel}")"
    display="$(backend_display_name "${variant}")"
    core_optdepends+="  '${pkgname}: ${display} acceleration backend'"$'\n'
    backend_names+="  '${pkgname}'"$'\n'
    backend_variants+="  '${variant}'"$'\n'
  done

  for variant in "${available_variants[@]}"; do
    asset_json="${variant_assets[${variant}]}"
    asset_name="$(jq -er '.name' <<< "${asset_json}")"
    asset_url="$(jq -er '.url' <<< "${asset_json}")"
    asset_sha="${variant_shas[${variant}]}"
    local_name="backend-${variant}-${asset_name}"
    pkgname="$(backend_package_name "${variant}" "${channel}")"
    display="$(backend_display_name "${variant}")"
    backend_package_fields "${variant}"
    capability="llama-cpp-${variant}"

    optdepends_block=''
    if [[ -n "${backend_optdepends}" ]]; then
      optdepends_block="  optdepends=("$'\n'"${backend_optdepends}  )"$'\n'
    fi

    source_lines+="  '${local_name}::${asset_url}'"$'\n'
    checksum_lines+="  '${asset_sha}'"$'\n'
    noextract_lines+="  '${local_name}'"$'\n'
    backend_archive_map+="  [${variant}]='${local_name}'"$'\n'
    backend_plugin_map+="  [${variant}]='${plugin}'"$'\n'

    conflicts=''
    for conflict_candidate in "${variants[@]}"; do
      [[ "${conflict_candidate}" == "${variant}" ]] && continue
      conflicts+="  'llama-cpp-${conflict_candidate}'"$'\n'
    done

    if [[ "${variant}" == cuda12 || "${variant}" == cuda13 ]]; then
      extra_asset="${variant_cudart_assets[${variant}]}"
      extra_name="$(jq -er '.name' <<< "${extra_asset}")"
      extra_root="${extra_name%.tar.gz}"
      extra_url="$(jq -er '.url' <<< "${extra_asset}")"
      extra_sha="${cudart_shas[${variant}]}"
      extra_local="cudart-${variant}-${extra_name}"
      source_lines+="  '${extra_local}::${extra_url}'"$'\n'
      checksum_lines+="  '${extra_sha}'"$'\n'
      noextract_lines+="  '${extra_local}'"$'\n'
      cudart_archive_map+="  [${variant}]='${extra_local}'"$'\n'
      cudart_root_map+="  [${variant}]='${extra_root}'"$'\n'
    fi

    package_functions+="package_${pkgname}() {
  pkgdesc='Official llama.cpp ${channel_label} ${display} backend'
  provides=('${capability}')
  depends=(
    \"\${pkgbase}=\${pkgver}-\${pkgrel}\"
${backend_depends}  )
${optdepends_block}  conflicts=(
${conflicts}  )
  _package_backend '${variant}'
}

"
  done

  declare -A template_values=(
    [CORE_PKGNAME]="${core_pkgname}"
    [PKGVER]="${pkgver}"
    [PKGREL]="${pkgrel}"
    [CHANNEL_LABEL]="${channel_label}"
    [UPSTREAM_TAG]="${asset_tag}"
    [CORE_LOCAL]="${core_local}"
    [CORE_URL]="${core_url}"
    [CORE_SHA]="${core_sha}"
    [CHANNEL_CONFLICTS]="${channel_conflicts}"
    [CORE_OPTDEPENDS]="${core_optdepends}"
    [BACKEND_PKGNAMES]="${backend_names}"
    [BACKEND_VARIANTS]="${backend_variants}"
    [BACKEND_SOURCES]="${source_lines}"
    [BACKEND_CHECKSUMS]="${checksum_lines}"
    [BACKEND_NOEXTRACT]="${noextract_lines}"
    [BACKEND_ARCHIVE_MAP]="${backend_archive_map}"
    [BACKEND_PLUGIN_MAP]="${backend_plugin_map}"
    [CUDART_ARCHIVE_MAP]="${cudart_archive_map}"
    [CUDART_ROOT_MAP]="${cudart_root_map}"
    [BACKEND_PACKAGE_FUNCTIONS]="${package_functions}"
  )
  render_pkgbuild "${split_template}" "${stage_channel_dir}/PKGBUILD"
  printf 'channel=%s\npackage_tag=%s\nasset_tag=%s\npkgver=%s\npkgrel=%s\nvariants=%s\n' \
    "${channel}" "${package_tag}" "${asset_tag}" "${pkgver}" "${pkgrel}" \
    "$(IFS=,; printf '%s' "${available_variants[*]}")" \
    > "${stage_channel_dir}/.upstream-generated"

  mkdir -p "${destination}"
  if ! mv -f -- "${stage_channel_dir}/PKGBUILD" "${destination}/PKGBUILD" \
    || ! mv -f -- "${stage_channel_dir}/.upstream-generated" "${destination}/.upstream-generated"; then
    printf 'Failed to replace generated metadata for the %s package base.\n' "${channel}" >&2
    return 1
  fi
  printf 'Updated %s package base %s from binary tag %s (%s backend packages).\n' \
    "${channel}" "${package_tag}" "${asset_tag}" "${#available_variants[@]}"
}

stage_channel "${stable_release}" stable "${stable_binary_release}"
stage_channel "${prerelease_release}" prerelease "${prerelease_release}"
