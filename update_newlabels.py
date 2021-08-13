#!/usr/bin/env python3
import argparse
import sys

from kubernetes import client, config


def get_uniq_group_ids(groupids):
    # Specific correct identification of the group ID: tf1 => -tf1- to prevent getting tf1sf groupId.
    if groupids is None:
        exact_groupids = list()
    else:
        exact_groupids = [ f"-{idval}-" for idval in groupids ]

    return exact_groupids

def get_segmenter_deployments_namespaces(name, groupids):
    clientappsv1 = client.AppsV1Api()
    result = clientappsv1.list_deployment_for_all_namespaces(label_selector=f"type=unit,vendor=quortex")
    segmenterdeps = list()
    seg_namspaces = set()
    for item in result.items:
        # Keep deployments starting with good basename. default is "segmenter"
        if item.metadata.name.startswith(f"{name}-"):
            # Filter groups depending groupids filter
            if groupids:
                for groupid in groupids:
                    if "group" in item.spec.template.metadata.labels:
                        if groupid in item.spec.template.metadata.labels["group"]:
                            segmenterdeps.append(item)
                            seg_namspaces.add(item.metadata.namespace)
                            break
            else:
                segmenterdeps.append(item)
                seg_namspaces.add(item.metadata.namespace)
    return segmenterdeps, list(seg_namspaces)


def get_segmenter_unit_services(name, namespace, groupids):
    clientcorev1 = client.CoreV1Api()
    result = clientcorev1.list_namespaced_service(namespace, label_selector="type=unit")
    services = list()
    map_access = dict()
    for item in result.items:
        # Keep services starting with good basename. default is "segmenter"
        if item.metadata.name.startswith(f"{name}-"):
            # Filter groups depending groupids filter
            if groupids:
                for groupid in groupids:
                    if "app" in item.metadata.labels:
                        if groupid in item.metadata.labels["app"]:
                            prety_group = groupid.replace('-', '')
                            if prety_group not in map_access:
                                map_access[prety_group] =  list()
                            map_access[prety_group].append(len(services))
                            services.append(item)
                            break
            else:
                services.append(item)

    return services, map_access


def get_segmenter_mongo_services(name, namespace, groupids):
    clientcorev1 = client.CoreV1Api()
    result = clientcorev1.list_namespaced_service(namespace)
    services = list()
    map_access = dict()
    for item in result.items:
        # Keep services starting with good basename. default is "segmenter" and the label with mongo
        if item.metadata.name.startswith(f"{name}-") and "mongo" in item.metadata.labels.get("app", ""):
            # Filter groups depending groupids filter
            if groupids:
                for groupid in groupids:
                    if groupid in item.metadata.labels["app"]:
                        prety_group = groupid.replace('-', '')
                        if prety_group not in map_access:
                            map_access[prety_group] =  list()
                        map_access[prety_group].append(len(services))
                        services.append(item)
                        break
            else:
                services.append(item)

    return services, map_access


def get_segmenter_mongo_statefulset(name, namespace, groupids):
    clientappsv1 = client.AppsV1Api()
    result = clientappsv1.list_namespaced_stateful_set(namespace, label_selector=f"type=dbase,vendor=quortex")
    statefulset = list()
    map_access = dict()
    for item in result.items:
        # Keep services starting with good basename. default is "segmenter"
        if item.metadata.name.startswith(f"{name}-"):
            # Filter groups depending groupids filter
            if groupids:
                for groupid in groupids:
                    if "app" in item.metadata.labels:
                        if groupid in item.metadata.labels["app"]:
                            prety_group = groupid.replace('-', '')
                            if prety_group not in map_access:
                                map_access[prety_group] =  list()
                            map_access[prety_group].append(len(statefulset))
                            statefulset.append(item)
                            break
            else:
                statefulset.append(item)

    return statefulset, map_access

def patch_segmenter_service(service, do_update, custom_parameters):
    clientcorev1 = client.CoreV1Api()
    patch = {"metadata": {"labels": dict()}}
    # Basic check of custom parametes: some are mandatory app_name, app_managed.
    if not custom_parameters:
        return

    # Add the new labels if some are missing.
    new_labels = service.metadata.labels
    label_patch_info = ""
    if 'app.kubernetes.io/instance' not in new_labels and 'app' in new_labels:
        new_labels['app.kubernetes.io/instance'] = new_labels['app']
        label_patch_info = f"app.kube.instance={new_labels['app.kubernetes.io/instance']}"
    if custom_parameters.get('app_name') and 'app.kubernetes.io/name' not in new_labels:
        new_labels['app.kubernetes.io/name'] = custom_parameters['app_name']
        label_patch_info = f"{label_patch_info} app.kube.name={new_labels['app.kubernetes.io/name']}"
    if custom_parameters.get('app_managed') and 'app.kubernetes.io/managed-by' not in new_labels:
        new_labels['app.kubernetes.io/managed-by'] = custom_parameters['app_managed']
        label_patch_info = f"{label_patch_info} app.kube.managed={new_labels['app.kubernetes.io/managed-by']}"
    if 'vendor' not in new_labels:
        new_labels['vendor'] = 'quortex'
        label_patch_info = f"{label_patch_info} vendor={new_labels['vendor']}"
    if custom_parameters.get('app_type') and 'type' not in new_labels:
        new_labels['type'] = custom_parameters['app_type']
        label_patch_info = f"{label_patch_info} type={new_labels['type']}"
    if custom_parameters.get('set_group', False) and 'group' not in new_labels and 'app' in new_labels:
        new_labels['group'] = new_labels['app']
        label_patch_info = f"{label_patch_info} group={new_labels['group']}"

    if label_patch_info and new_labels:
        # Aply the label update.
        print(f"{'(DRY_RUN)' if not do_update else ''}SERVICE <{service.metadata.name}>: updating labels with the following")
        print(f"- labels: {label_patch_info}")
        if do_update:
            patch['metadata']['labels'] = new_labels
            clientcorev1.patch_namespaced_service(service.metadata.name, service.metadata.namespace, patch)

            # Check labels are applied correctly.
            new_service = clientcorev1.read_namespaced_service(service.metadata.name,  service.metadata.namespace)
            if new_service.metadata.labels != new_labels:
                print(f"ERROR: SERVICE {service.metadata.name} on patching label: expected={new_labels} read={new_service.metadata.labels}")
    else:
        print(f"SERVICE {service.metadata.name}: no update labels")


def patch_segmenter_stateful_set(statefullset, do_update, custom_parameters):
    clientappsv1 = client.AppsV1Api()
    # Basic check of custom parametes: some are mandatory app_name, app_managed.
    if not custom_parameters:
        return

    # Spec.template labels update new labels if needed.
    spec_new_labels = statefullset.spec.template.metadata.labels
    spec_label_patch_info = ""
    if 'app.kubernetes.io/instance' not in spec_new_labels and 'app' in spec_new_labels:
        spec_new_labels['app.kubernetes.io/instance'] = spec_new_labels['app']
        spec_label_patch_info = f"app.kube.instance={spec_new_labels['app.kubernetes.io/instance']}"
    if custom_parameters.get('app_name') and 'app.kubernetes.io/name' not in spec_new_labels:
        spec_new_labels['app.kubernetes.io/name'] = custom_parameters['app_name']
        spec_label_patch_info = f"{spec_label_patch_info} app.kube.name={spec_new_labels['app.kubernetes.io/name']}"
    if custom_parameters.get('app_type') and 'type' not in spec_new_labels:
        spec_new_labels['type'] = custom_parameters['app_type']
        spec_label_patch_info = f"{spec_label_patch_info} type={spec_new_labels['type']}"
    if 'vendor' not in spec_new_labels:
        spec_new_labels['vendor'] = 'quortex'
        spec_label_patch_info = f"{spec_label_patch_info} vendor={spec_new_labels['vendor']}"

    # metadata labels update new labels if needed.
    metadata_new_labels = statefullset.metadata.labels
    metadata_label_patch_info = ""
    if 'app.kubernetes.io/instance' not in metadata_new_labels and 'app' in metadata_new_labels:
        metadata_new_labels['app.kubernetes.io/instance'] = metadata_new_labels['app']
        metadata_label_patch_info = f"app.kube.instance={metadata_new_labels['app.kubernetes.io/instance']}"
    if custom_parameters.get('app_name') and 'app.kubernetes.io/name' not in metadata_new_labels:
        metadata_new_labels['app.kubernetes.io/name'] = custom_parameters['app_name']
        metadata_label_patch_info = f"{metadata_label_patch_info} app.kube.name={metadata_new_labels['app.kubernetes.io/name']}"
    if custom_parameters.get('app_managed') and 'app.kubernetes.io/managed-by' not in metadata_new_labels:
        metadata_new_labels['app.kubernetes.io/managed-by'] = custom_parameters['app_managed']
        metadata_label_patch_info = f"{metadata_label_patch_info} app.kube.managed={metadata_new_labels['app.kubernetes.io/managed-by']}"
    if 'group' not in metadata_new_labels and 'app' in metadata_new_labels:
        metadata_new_labels['group'] = metadata_new_labels['app']
        metadata_label_patch_info = f"{metadata_label_patch_info} group={metadata_new_labels['group']}"

    if spec_label_patch_info and spec_new_labels or metadata_label_patch_info and metadata_new_labels:
        # Aply the labels update.
        print(f"{'(DRY_RUN)' if not do_update else ''}STATEFULSET <{statefullset.metadata.name}>: updating labels with the following")
        print(f"- labels template: {spec_label_patch_info}")
        print(f"- labels metadata: {metadata_label_patch_info}")
        if do_update:
            # Prepare the patch operation info and send the request.
            patch = dict()
            if spec_new_labels:
                spec_patch = {"spec": {"template": {"metadata": {"labels": spec_new_labels}}}}
                patch.update(spec_patch)
            if metadata_new_labels:
                metadata_patch = {"metadata": {"labels": metadata_new_labels}}
                patch.update(metadata_patch)
            clientappsv1.patch_namespaced_stateful_set(statefullset.metadata.name, statefullset.metadata.namespace, patch)

            # Check labels are applied correctly.
            new_statefulset = clientappsv1.read_namespaced_stateful_set(statefullset.metadata.name,  statefullset.metadata.namespace)
            if new_statefulset.spec.template.metadata.labels == spec_new_labels or new_statefulset.metadata.labels == metadata_new_labels:
                input("Press <ENTER> after all MONGO deployments are restarted (done after statefulset label update)")
            else:
                print(f"ERROR: STATEFULSET {statefullset.metadata.name} on patching label:")
                print(f"-templace expected={spec_new_labels} read={new_statefulset.spec.template.metadata.labels }")
                print(f"-metadata expected={metadata_new_labels} read={new_statefulset.metadata.labels}")
    else:
        print(f"STATEFULSET {statefullset.metadata.name}: no update labels")


def process_new_labels_update(user_args):
    # Get user arguments.
    name = user_args.name
    groupids = user_args.group
    namespace_select = user_args.namespace
    do_update = user_args.update

    print(f"=>{'(!!! DRY_RUN !!!)' if not do_update else ''} Updating segmenter labels for groups: {','.join(groupids)} (namespace={namespace_select})")
    # Setup unique group id name.
    unique_groupids = get_uniq_group_ids(groupids)

    # Get the Segmenter service unit.
    print("=> Parsing service segmenter UNIT")
    segmenter_services, seg_service_groups = get_segmenter_unit_services(name, namespace_select, unique_groupids)
    if seg_service_groups:
        print(f"Found {len(segmenter_services)} services.")
    else:
        print("No Service found, exit")
        sys.exit(-1)

    # Get the Segmenter service mongo.
    print("=> Parsing service segmenter MONGO")
    mongo_services, mongo_service_groups = get_segmenter_mongo_services(name, namespace_select, unique_groupids)
    if mongo_service_groups:
        print(f"Found {len(mongo_services)} services.")
    else:
        print("No Service found, exit")
        sys.exit(-1)

    # Get the Segmenter statefulset mongo.
    print("=> Parsing statefulset segmenter MONGO")
    mongo_statefulset, mongo_statefulset_groups = get_segmenter_mongo_statefulset(name, namespace_select, unique_groupids)
    if mongo_statefulset_groups:
        print(f"Found {len(mongo_statefulset)} statefulset.")
    else:
        print("No Statefulset found, exit")
        sys.exit(-1)

    # Loop all groups to patch/update the service labels.
    for group_name in groupids:
        print(f"\n=> Updating labels for group: {group_name}")
        # Servive UNIT label patching
        parameters = {'app_name': 'segmenter-unit', 'app_managed': 'segmenter-daemon'}
        for srv_idx in seg_service_groups.get(group_name, list()):
            patch_segmenter_service(segmenter_services[srv_idx], do_update, parameters)

        # Servive MONGO label patching
        if len(mongo_service_groups.get(group_name, list())) == 1:
            parameters = {'app_name': 'segmenter-mongo', 'app_managed': 'segmenter-daemon',
                          'app_type': 'dbase', 'set_group': True}
            srv_idx = mongo_service_groups[group_name][0]
            patch_segmenter_service(mongo_services[srv_idx], do_update, parameters)
        else:
            print(f"WARNING: bypassing MONGO service patch (nb_services={len(mongo_service_groups.get(group_name, list()))})")

        # Statefulset MONGO label patching
        if len(mongo_statefulset_groups.get(group_name, list())) == 1:
            parameters = {'app_name': 'ssegmenter-mongo', 'app_managed': 'segmenter-daemon',
                          'app_type': 'dbase'}
            sts_idx = mongo_statefulset_groups[group_name][0]
            patch_segmenter_stateful_set(mongo_statefulset[sts_idx], do_update, parameters)
        else:
            print(f"WARNING: bypassing MONGO statefulset patch (nb_services={len(mongo_statefulset_groups.get(group_name, list()))})")


if __name__ == '__main__':
    # Parse argument
    parser = argparse.ArgumentParser()
    required = parser.add_argument_group('required arguments')
    required.add_argument("-g", "--group",          default=None,                           help="Specify the list of group to update",     nargs='+')
    required.add_argument("-n", "--name",           default="segmenter",                    help="Specify the basename of the segmenters")
    required.add_argument("-s", "--namespace",      default="reference",                    help="Specify the namespace og th segmenters")
    required.add_argument("-u", "--update",         default=False,                          help="Do the update labels operation",          action='store_true')

    # Get arguments
    args = parser.parse_args()

    # Load current kube config
    try:
        config.load_kube_config()
    except config.config_exception.ConfigException:
        print("Missing kube config file")
        sys.exit(-1)

    # Execute the label update.
    process_new_labels_update(args)
