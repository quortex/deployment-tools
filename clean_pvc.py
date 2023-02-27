from kubernetes import config, client
import argparse

def parse_args():
    parser = argparse.ArgumentParser(prog="clean_pvc.py", description="Clean unbound PVCs in reference namespace")
    parser.add_argument('--run', action='store_true', default=False, help="Run pvc deletion, default is false (=dry run)")

    return parser.parse_args()

if __name__ == "__main__":
    
    run = vars(parse_args())['run']
    print("Not dry-run, pvc will be deleted") if run else print("Running in dry-run mode")
    NAMESPACE = "reference"
    config.load_kube_config()
    kube_client = client.CoreV1Api()
    pvc_list = []

    for pvc in kube_client.list_namespaced_persistent_volume_claim(NAMESPACE).items:
        pvc_list.append(pvc.metadata.name)
        mounted_pvc_list = []
    for pod in kube_client.list_namespaced_pod(NAMESPACE).items:
        if str(pod.spec.volumes) != "None":
            for volume in pod.spec.volumes:
                if str(volume.persistent_volume_claim) != "None":
                    mounted_pvc_list.append(volume.persistent_volume_claim.claim_name)

    unmounted_pvc = set(pvc_list) - set(mounted_pvc_list)
    print("Total: ",len(pvc_list))
    print("Mounted: ",len(mounted_pvc_list))
    print("Unmounted: ",len(unmounted_pvc))

    for pvc in sorted(list(unmounted_pvc)):
        print("Deleting pvc :",pvc)
        if run:
            kube_client.delete_namespaced_persistent_volume_claim(pvc, NAMESPACE)

