# deployment-tools

A toolkit repo for Quortex deployment.

## Configuration Scripts

The scripts `pushconfig.sh` and `getconfig.sh` are made to push and retrieve configurations in bulk from and to the Quortex workflow.

### File format

Both of these scripts relies on a folder to know what to push or what to retrieve.

These files should also follow a strict JSON format :

```json
[
    # List of types of configuration to push
    {
        "url" : "/url/of/this/configuration/type/endpoint",
        "confs : [
            # List of configuration of this type to push
        ]
    }
]
```

- The script `pushconfig.sh` only need one folder, provided by `-f CONFIG_FOLDER` and will crawl it to know which service and what configuration type to push.

- The script `getconfig.sh` use the provided `-i INPUT_FOLDER` to know which configuration to retrieve from the cluster, and can either update this folder with the current configuration (usage by default) or can also write the downloaded configurations into a different folder with the `-o OUTPUT_FOLDER` option.

### API

Both can be used with the **Kubernetes API** or with the **external API**. By default, they use the kubernetes API, to use the external use the options `-A api.mycluster.com -u myuser:mypassword`.

---

## Update scripts

The script update_segmenter.py allows the massive update of segmenters unit.

By default, the script does a "dry-run" of the update process. Use the "--upgrade" argument to actually run the update.

In addition, using the "--display" argument, the script acts as a monitoring tool to visualize the list of segmenters currently running, and the version that each segmenter is running. It is useful to oversee the ongoing upgrade.

### Dependencies

The script update_segmenter.py requires following dependencies:

- asyncio
- kubernetes

```
#pip3 install asyncio kubernetes
```

### Usage

- -h --help: Show this help message
- -v VERSION, --version VERSION: The new segmenter version to update
- -n NAME, --name NAME: Specify the basename of the segmenters
- -d, --display: Display ongoing update
- -u, --upgrade: Do upgrade
- -o, --overbandwidth: Allow overbandwidth for mono segmenter
- -p, --parallel: Allow parallel update of segmenters
- -g GROUP [GROUP ...], --group GROUP [GROUP ...]: Specify the list of group to update

### Example

Show the current running version:

```
$./update_segmenter.py --display
```

Upgrade the version of units sequentially:

```
$./update_segmenter.py --display --upgrade --version rel-x.x.x
```

Upgrade the version of units in parallel and allow over bandwidth consumption:

```
$./update_segmenter.py --display --upgrade --parallel --version rel-x.x.x --overbandwidth
```

---

## drainnode

The purpose of this script is to perform node-by-node cluster rolling updates.
It allows to make the targeted nodes unschedulable and to drain them one by one.

**Drain out nodes based on node names.**

```
drainnode node1 node2
```

**Drain out nodes based on labels.**

```
drainnode -l foo=bar -l bar=baz
```

### Usage

- -h --help: show the help message
- -l --selector: selectors (label query) to filter nodes on
- -c --count: count of non-running pods (completed/error) in the cluster before starting draining process
- --dry-run: simulate nodes drain
- -y --yes: run non interractively
- --no-color: remove the additional color from the output

---

## clean_pvc

The purpose of this script is to delete unmounted pvcs in the reference namespace.

### Usage

- -h --help: show help message
- --run: run deletion, default is false so nothing is deleted - aka default is dry-run.

---

## init_tf_backend_aws

Provision the resources needed to store terraform states on AWS.

A bucket on Amazon S3 will be created, as well as a Dynamo DB table to support
state locking and consistency checking.

### Usage

```
Usage : ./init_tf_backend_aws.sh -n NAME [options]

Mandatory arguments :
    -n NAME      Set the name of created resources.
Available options :
    -r REGION                   Specify the region in which to create the resources.
    -p PREFIXED                 Whether to prefix the name with "<ACCOUNT ID>-tfstate-" (default true)
    -b BLOCK_PUBLIC_ACCESS      Whether to block public access for s3 bucket (default true)
    -y                          Execute script in non interactive mode.
    -h                          Display this help.
```

---

## get_cluster_config

Compute a cluster Config from a given ServiceAccount.

It requests the different kubernetes resources in order to build a cluster Config for a given ServiceAccount.

### Usage

```
Usage : $0 -s SERVICE_ACCOUNT [options]

Mandatory arguments :
    -s SERVICE_ACCOUNT    The name of the ServiceAccount to use for the config.
Available options :
    -n NAMESPACE      The namespace of the ServiceAccount to use for the config. (default ${NAMESPACE}).
    -c CLUSTER_NAME   Set the name of the cluster (default ${CLUSTER_NAME}).
    -h                Display this help.
```
