# Dynamic Application Security Testing with RapiDAST

To run RapiDAST on Trustify (TPA v2) you need to first setup infrastructure
with the Trustify services up and running. To make this task as easy as
possible this repository comes with the `run.sh` helper script.

## Running All Analysis Tasks at Once

To run all analysis tasks, run

```sh
$ ./run.sh all
```

This will

1. create `.workspace` workspace directory in the same directory as `run.sh` is
1. clone [RapiDAST](https://github.com/RedHatProductSecurity/rapidast)
   repository into it
1. create a Python virtual environment and install RapiDAST runtime
   dependencies inside it
1. spawn the container with Trustify service
   * this may also build the custom container image with `trustd`
   * environment variables that can be used to customize this step:
     * `TRUSTIFICATION_REGISTRY` - the container registry with Trustify images
       (default: `ghcr.io/trustification`)
     * `TRUSTD_IMAGE` - the name of the Trustify image (default: `trustd`)
     * `TRUSTD_VERSION` - the tag/version of the Trustify image (default:
       `latest`)
     * `TRUSTD_VERSION_DAST` - the tag/version used to tag the customized
       `TRUSTD_IMAGE` (default: `dast`)
1. run RapiDAST on exposed APIs of the Trustify service
1. stop the container

Then you can run

```sh
$ ./run.sh serve
```

and access the reports from your browser via localhost: http://0.0.0.0:8765/
In case the default HTTP port 8765 is taken you can pass your own chosen port
number to the `serve` command:

```sh
$ ./run.sh serve 8484
```
