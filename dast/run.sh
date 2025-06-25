#!/bin/bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

WORKSPACE="${HERE}/.workspace"
VENVSPACE="${WORKSPACE}/.venv"
RAPIDAST="rapidast"
RAPIDAST_REPO_URL="https://github.com/RedHatProductSecurity/rapidast.git"
RAPIDAST_CONFIG="${WORKSPACE}/rapidast-config.yaml"
HTTP_PORT="8765"

TRUSTIFICATION_REGISTRY="${TRUSTIFICATION_REGISTRY:-ghcr.io/trustification}"
TRUSTD_IMAGE="${TRUSTD_IMAGE:-trustd}"
TRUSTD_VERSION="${TRUSTD_VERSION:-latest}"
TRUSTD_VERSION_DAST="${TRUSTD_VERSION_DAST:-dast}"

CONTAINER="${TRUSTD_IMAGE}_${TRUSTD_VERSION_DAST}"
RETRIES=60
DELAY=5

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

    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
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
                die "${FUNCNAME[0]}: Internal error"
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
            die "${FUNCNAME[0]}: Invalid operation '${op}'"
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

function build_container() (
    local skip="no"

    local opts=$(
        getopt \
            --options f \
            --longoptions force,skip-build \
            --name ${FUNCNAME[0]} \
            -- \
            "$@"
    )

    eval set -- "${opts}"

    if podman container exists "${CONTAINER}"; then
        skip="yes"
    fi
    if podman image exists "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}"; then
        skip="yes"
    fi

    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            -f | --force)
                skip="no"
                shift
            ;;
            --skip-build)
                skip="yes"
                shift
            ;;
            --)
                shift
                break
            ;;
            *)
                die "${FUNCNAME[0]}: Internal error"
            ;;
        esac
    done

    if [[ "${skip}" = "yes" ]]; then
        return
    fi

    if podman container exists "${CONTAINER}"; then
        podman stop -i "${CONTAINER}"
        podman rm -if "${CONTAINER}"
    fi
    if podman image exists "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}"; then
        podman rmi -if "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}"
    fi

    cd "${HERE}"
    podman build \
        -f ./Containerfile.trustd \
        -t "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}" \
        --build-arg REGISTRY="${TRUSTIFICATION_REGISTRY}" \
        --build-arg IMAGE="${TRUSTD_IMAGE}" \
        --build-arg TAG="${TRUSTD_VERSION}" \
        .
)

function cstatus() {
    podman ps -a --format='{{.Names}}|{{.Status}}' \
    | grep -Ee '^'"${1:-}"'\|' \
    | cut -d'|' -f2 \
    | cut -d' ' -f1
}

function cwait() {
    local counter=1
    local status

    while true; do
        echo "Waiting for $1 to be up and running (#${counter})"
        status="$(cstatus "$1" 2>/dev/null)"
        case "${status}" in
            Up | Running)
                break
            ;;
            Created | Initialized)
                sleep ${DELAY}
            ;;
            *)
                error "$1 is in ${status:-unknown} state"
                return 1
            ;;
        esac
        counter=$(( counter + 1 ))
    done
    echo "$1 is up and running"
}

function cready() {
    [[ "$(cstatus "$1" 2>/dev/null)" == [UR][pu]* ]] \
    && podman exec "$1" true >/dev/null 2>&1
}

function start_container() (
    if ! podman image exists "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}"; then
        build_container
    fi

    export SELINUX_VOLUME_OPTIONS=':Z'

    cd "${WORKSPACE}"
    if ! cready "${CONTAINER}"; then
        podman run \
            --name "${CONTAINER}" \
            -p "8080:8080" \
            -d \
            "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}"
        cwait "${CONTAINER}"
    fi

    if ! cready "${CONTAINER}"; then
        die "Container" "${CONTAINER}" "is not ready." \
            "Please resolve the issue and try again"
    fi
)

function show_container_logs() {
    if podman container exists "${CONTAINER}"; then
        podman logs "$@" "${CONTAINER}"
    fi
}

function stop_container() {
    podman stop -i "${CONTAINER}"
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

function service_ready() {
    { curl -f "$1" | jq; } >/dev/null 2>&1
}

function service_wait() {
    local counter=1

    while [[ ${counter} -le ${RETRIES} ]]; do
        echo "Waiting on $1 to be ready (#${counter})"
        sleep ${DELAY}
        if service_ready "$1"; then
            echo "$1 is ready"
            break
        fi
        counter=$(( counter + 1 ))
    done
}

function analyze() (
    local inside_venv=$(command -v deactivate >/dev/null 2>&1; echo -n $?)

    service_wait "$3"
    if ! service_ready "$3"; then
        error "$1 is not ready"
        return 1
    fi
    if [[ ${inside_venv} -eq 1 ]]; then
        cd "${WORKSPACE}/${RAPIDAST}"
        . "${VENVSPACE}/bin/activate"
    fi
    config "$1" "$2" "$3" > "${RAPIDAST_CONFIG}"
    ./rapidast.py --config "${RAPIDAST_CONFIG}"
    if [[ $? -eq 0 ]]; then
        config "$1" "$2" "$3" "y" > "${RAPIDAST_CONFIG}"
        ./rapidast.py --config "${RAPIDAST_CONFIG}"
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
            *) die "${FUNCNAME[0]}: Unknown service API '$1'" ;;
        esac
        shift 1
    done
    deactivate
)

function runall() (
    ws_init
    start_container
    analyze_all
    stop_container
)

function serve() {
    python \
        -m http.server \
        "${1:-${HTTP_PORT}}" \
        -d "${WORKSPACE}/${RAPIDAST}/results"
}

function clean() {
    local mode="repos"

    local opts=$(
        getopt \
            --options a \
            --longoption all \
            --name ${FUNCNAME[0]} \
            -- \
            "$@"
    )

    eval set -- "${opts}"

    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            -a | --all)
                mode="all"
                shift
            ;;
            --)
                shift
                break
            ;;
            *)
                die "${FUNCNAME[0]}: Internal error"
            ;;
        esac
    done

    case "${mode}" in
        repos)
            cd "${WORKSPACE}/${RAPIDAST}"
            git clean -dfx
        ;;
        all)
            podman stop -i "${CONTAINER}"
            podman rm -if "${CONTAINER}"
            podman rmi -if "${TRUSTD_IMAGE}:${TRUSTD_VERSION_DAST}"
            rm -rf "${WORKSPACE}"
        ;;
        *)
            die "${FUNCNAME[0]}: Invalid mode '${mode}'"
        ;;
    esac
}

function usage() {
    cat <<-__EOF__
	Usage: $0 <COMMAND>

	where <COMMAND> is one of
	  all     analyze all APIs
	  build   build or rebuild the container image
	  clean   remove analysis products (reports) or entire work space
	  clist   show status of containers
	  clogs   show logs of the container
	  cstart  start the container
	  cstop   stop the container
	  dast    run RapiDAST on given APIs
	  help    print this screen and exit
	  init    initialize a work space
	  serve   run HTTP server with results (default port: ${HTTP_PORT})
	  update  update the work space
	__EOF__
    exit 0
}

function main() (
    local cmd="${1:-help}"

    [[ -z "${1:-}" ]] || shift 1

    case "${cmd}" in
        all) runall ;;
        build) build_container "$@" ;;
        clean) clean "$@" ;;
        clist) podman ps "$@" ;;
        clogs) show_container_logs "$@" ;;
        cstart) start_container ;;
        cstop) stop_container ;;
        dast) dast "$@" ;;
        help) usage ;;
        init) ws_init ;;
        serve) serve "$@" ;;
        update) ws_update ;;
        *) die "$0: Unknown command: '${cmd}'" ;;
    esac
)

main "$@"
