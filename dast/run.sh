#!/bin/bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

WORKSPACE="${HERE}/.workspace"
VENVSPACE="${WORKSPACE}/.venv"
RAPIDAST="rapidast"
RAPIDAST_REPO_URL="https://github.com/RedHatProductSecurity/rapidast.git"
HTTP_PORT="8765"

TRUSTIFICATION_REGISTRY="${TRUSTIFICATION_REGISTRY:-ghcr.io/trustification}"
TRUSTD_IMAGE="${TRUSTD_IMAGE:-trustd}"
TRUSTD_VERSION="${TRUSTD_VERSION:-latest}"

function error() {
    echo -e "\e[31m[ERROR]" $* "\e[0m" >&2
}

function skipped() {
    echo -e "\e[36m[SKIPPED]" $* "\e[0m" >&2
}

function die() {
    error $*
    exit 1
}

function need_arg() {
    [[ "${1:-}" ]] || die "${FUNCNAME[1]}: Missing positional argument"
}

function ensure_dir() {
    if [[ ! -d "$1" ]]; then
        mkdir -vp "$1"
    fi
}

function do_repo_op() {
    local url=""
    local name=""
    local branch="main"
    local op=""

    local opts=$(
        getopt \
            --options b:n: \
            --longoptions branch:,name: \
            --name ${FUNCNAME[0]} \
            -- \
            "$@"
    )

    eval set -- "${opts}"

    while [[ -n "$@" ]]; do
        case "$1" in
            -b | --branch)
                branch="$2"
                shift 2
                ;;
            -n | --name)
                name="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                die "${FUNCNAME[0]}: Unrecognized option: '$1'"
                ;;
        esac
    done

    need_arg "$2"
    url="$1"
    op="$2"

    if [[ -z "${name}" ]]; then
        name="${url##*/}"
        name="${name%.git}"
    fi

    case "${op}" in
        clone)
            if [[ ! -d "./${name}" ]]; then
                git clone "${url}" "${name}" -b "${branch}"
            fi
            ;;
        update)
            (cd "./${name}" && git pull --prune)
            ;;
        *)
            die "${FUNCNAME[0]}: Invalid operation: '${op}'"
            ;;
    esac
}

function setup_rapidast_venv() (
    cd "${WORKSPACE}/${RAPIDAST}"
    if [[ ! -d "${VENVSPACE}" ]]; then
        python -m venv "${VENVSPACE}"
        . "${VENVSPACE}/bin/activate"
        pip install -U pip
        pip install -r requirements.txt
        deactivate
    fi
)

function ws_init() (
    ensure_dir "${WORKSPACE}"
    cd "${WORKSPACE}"
    do_repo_op "${RAPIDAST_REPO_URL}" -n "${RAPIDAST}" -b main clone
    setup_rapidast_venv
)

function ws_update() (
    ws_init
    cd "${WORKSPACE}"
    do_repo_op "${RAPIDAST_REPO_URL}" update
)

function do_containers() (
    export SELINUX_VOLUME_OPTIONS=':Z'
    export TRUSTIFICATION_REGISTRY="${TRUSTIFICATION_REGISTRY}"
    export TRUSTD_IMAGE="${TRUSTD_IMAGE}"
    export TRUSTD_VERSION="${TRUSTD_VERSION}"
    export WORKSPACE="${WORKSPACE}"

    cd "${WORKSPACE}"
    podman-compose \
        -f ../compose.yaml \
        "$@"
)

function start_containers() {
    do_containers up -d
}

function list_containers() {
    do_containers ps "$@"
}

function show_containers_logs() {
    do_containers logs "$@"
}

function stop_containers() {
    do_containers down
}

# $1 - short name
# $2 - URL
# $3 - API URL
# $4 - active (y/n)
function config() {
    echo "config:"
    echo "  configVersion: 4"
    echo ""
    echo "application:"
    echo "  shortName: \"$1\""
    echo "  url: \"$2\""
    echo ""
    echo "general:"
    echo "  container:"
    echo "    type: \"podman\""
    echo ""
    echo "scanners:"
    echo "  zap:"
    echo "    apiScan:"
    echo "      apis:"
    echo "        apiUrl: \"$3\""
    echo "    passiveScan:"
    echo "      disableRules: \"2,10015,10027,10096,10024,10098,10023\""
    if [[ "${4:-n}" == "y" ]]; then
        echo "    activeScan:"
        echo "      policy: API-scan-minimal"
    fi
    echo "    report:"
    echo "      format: [\"json\", \"html\"]"
    echo "    miscOptions:"
    echo "      updateAddons: False"
}

function analyze() (
    local inside_venv=$(command -v deactivate >/dev/null 2>&1; echo -n $?)
    local ready=$(
        set -o pipefail
        { curl -f "$3" | jq; } >/dev/null 2>&1
        echo -n $?
    )

    if [[ ${ready} -ne 0 ]]; then
        error "$1 is not ready"
        return 1
    fi
    if [[ ${inside_venv} -eq 1 ]]; then
        cd "${WORKSPACE}/${RAPIDAST}"
        . "${VENVSPACE}/bin/activate"
    fi
    ./rapidast.py --config <(config "$1" "$2" "$3")
    if [[ $? -eq 0 ]]; then
        ./rapidast.py --config <(config "$1" "$2" "$3" "y")
    else
        skipped "$1 :: activeScan"
    fi
    if [[ ${inside_venv} -eq 1 ]]; then
        deactivate
    fi
)

function analyze_trustify_api() (
    analyze trustify-api "http://localhost:8080" "http://localhost:8080/openapi.json"
)

function analyze_all() (
    cd "${WORKSPACE}/${RAPIDAST}"
    . "${VENVSPACE}/bin/activate"
    analyze_trustify_api
    deactivate
)

function dast() (
    cd "${WORKSPACE}/${RAPIDAST}"
    . "${VENVSPACE}/bin/activate"
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            trustify) analyze_trustify_api ;;
            *) die "$0: Unknown service API: '$1'" ;;
        esac
        shift 1
    done
    deactivate
)

function runall() (
    ws_init
    start_containers
    analyze_all
    stop_containers
)

function serve() {
    python \
        -m http.server \
        "${1:-${HTTP_PORT}}" \
        -d "${WORKSPACE}/${RAPIDAST}/results"
}

function clean() {
    cd "${WORKSPACE}/${RAPIDAST}"
    git clean -dfx
}

function reset() {
    podman system reset -f
    rm -rfv "${WORKSPACE}"
}

function usage() {
    cat <<-__EOF__
	Usage: $0 <COMMAND>

	where <COMMAND> is one of
	  all     analyze all APIs
	  clean   remove analysis products (reports)
	  clist   show status of containers
	  clogs   show logs of containers
	  cstart  start containers
	  cstop   stop containers
	  dast    run RapiDAST on given APIs
	  help    print this screen and exit
	  init    initialize a work space
	  reset   remove workspaces and reset podman
	  serve   run HTTP server with results (default port: ${HTTP_PORT})
	  update  update the work space
	__EOF__
    exit 0
}

function main() (
    local cmd="${1:-help}"

    [[ -z "${1:-}" ]] || shift 1

    case "${cmd}" in
        all) runall "$@" ;;
        clean) clean ;;
        clist) list_containers "$@" ;;
        clogs) show_containers_logs "$@" ;;
        cstart) start_containers ;;
        cstop) stop_containers ;;
        dast) dast "$@" ;;
        help) usage ;;
        init) ws_init ;;
        reset) reset ;;
        serve) serve "$@" ;;
        update) ws_update ;;
        *) die "$0: Unknown command: '${cmd}'" ;;
    esac
)

main "$@"
