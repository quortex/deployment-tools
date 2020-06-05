# deployment-tools

A toolkit repo for Quortex deployment.

## Configuration Scripts

The scripts `pushconfig.sh` and `getconfig.sh` are made to push and retrieve configurations in bulk from and to the Quortex workflow. 

### File format

Both of these scripts relies on a folder to know what to push or what to retrieve.

These files should  also follow a strict JSON format :

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

Both can be used with the **Kubernetes API** or with the **external API**. By default, they use the kubernetes API, to use the external use the options `-A 
api.mycluster.com -u myuser:mypassword`.
