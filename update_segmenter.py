#!/usr/bin/env python3
import argparse
import ast
import asyncio
import curses
import json
import os
import sys
from copy import deepcopy

from kubernetes import client, config


###########################################
### GLOBAL VARIABLES ######################
###########################################
active = True
status = None

# To customize for column size
GROUPID_COLUMN_SIZE     = 0.075
ID_COLUMN_SIZE          = 0.075
DEP_COLUMN_SIZE         = 0.25
INUSE_COLUMN_SIZE       = 0.05
POD_COLUMN_SIZE         = 0.3
VERSION_COLUMN_SIZE     = 0.08
READY_COLUMN_SIZE       = 0.05
STATUS_COLUMN_SIZE      = 0.05

# Do not touch
GROUPID_COLUMN_START    = 0
ID_COLUMN_START         = 0
DEP_COLUMN_START        = 0
INUSE_COLUMN_START      = 0
POD_COLUMN_START        = 0
VERSION_COLUMN_START    = 0
READY_COLUMN_START      = 0
STATUS_COLUMN_START     = 0

BASELINE_OFFSET         = 0


###########################################
### COMMON FUNCTIONS ######################
###########################################
def get_ainode_all_conf():
    clientcorev1 = client.CoreV1Api()
    services = clientcorev1.list_service_for_all_namespaces(label_selector="app.kubernetes.io/name=segmenter-ainode,app.quortex.io/type=ainode")
    upstreamgroups = list()
    if len(services.items):
        service = services.items[0]
        upstreamgroups = ast.literal_eval(clientcorev1.connect_get_namespaced_service_proxy_with_path(f"{service.metadata.name}:api",service.metadata.namespace,"1.0/upstreamgroup"))
    return upstreamgroups

def get_segmenter_deployments(name, groupids=None):
    clientappsv1 = client.AppsV1Api()
    result = clientappsv1.list_deployment_for_all_namespaces(label_selector=f"type=unit,vendor=quortex")
    segmenterdeps = list()
    for item in result.items:
        # Keep deployments starting with good basename. default is "segmenter"
        if item.metadata.name.startswith(f"{name}-"):
            # Filter groups depending groupids filter
            if groupids is not None:
                for groupid in groupids:
                    if "group" in item.spec.template.metadata.labels:
                        if groupid in item.spec.template.metadata.labels["group"]:
                            segmenterdeps.append(item)
                            break
            else:
                segmenterdeps.append(item)
    return segmenterdeps

def get_pod_status(pod):
    if pod.metadata.deletion_timestamp is not None:
        return "Terminating"
    else:
        return pod.status.phase

def get_pod_ready_container(pod):
    nb = len(pod.spec.containers)
    ready = 0
    if pod.status.container_statuses is not None:
       for status in pod.status.container_statuses:
            if status.ready is True:
                ready +=1
    return f"{ready}/{nb}"

def get_selector_string_from_dep(deployment):
    selector = ""
    for key,val in deployment.spec.selector.match_labels.items():
        if selector == "":
            selector = selector + f"{key}={val}"
        else:
            selector = selector + f",{key}={val}"
    return selector

def get_group(deployment):
    return deployment.spec.template.metadata.labels['group']

###########################################
### DISPLAY FUNCTIONS #####################
###########################################
def update_sizing(window):
    global GROUPID_COLUMN_START
    global ID_COLUMN_START
    global DEP_COLUMN_START
    global INUSE_COLUMN_START
    global POD_COLUMN_START
    global VERSION_COLUMN_START
    global READY_COLUMN_START
    global STATUS_COLUMN_START

    width, _height = os.get_terminal_size()
    GROUPID_COLUMN_START    = 0
    ID_COLUMN_START         = GROUPID_COLUMN_START  + int(GROUPID_COLUMN_SIZE * width)
    DEP_COLUMN_START        = ID_COLUMN_START       + int(ID_COLUMN_SIZE * width)
    INUSE_COLUMN_START      = DEP_COLUMN_START      + int(DEP_COLUMN_SIZE * width)
    POD_COLUMN_START        = INUSE_COLUMN_START    + int(INUSE_COLUMN_SIZE * width)
    VERSION_COLUMN_START    = POD_COLUMN_START      + int(POD_COLUMN_SIZE * width)
    READY_COLUMN_START      = VERSION_COLUMN_START  + int(VERSION_COLUMN_SIZE * width)
    STATUS_COLUMN_START     = READY_COLUMN_START    + int(READY_COLUMN_SIZE * width)

    window.resize(50,width)

def get_pod_version(pod):
    for container in pod.spec.containers:
        if container.name.endswith("-unit"):
            return container.image.rsplit(":",1)[1]
    return "unknown"

def get_deployment_inuse(ainodeconf, depname):
    svc = depname.split("deployment")[0]+"service"
    for conf in ainodeconf:
        for upstream in conf["upstream"]:
            if svc in upstream["address"]:
                return "yes"
    return "no"

def get_ainode_conf(ainodesconfs,groupname):
    groupconf = list()
    for ainodeconf in ainodesconfs:
        if groupname in ainodeconf['location']:
            groupconf.append(ainodeconf)
    return groupconf

def get_segmenter_status(name):
    status = dict()
    clientcorev1 = client.CoreV1Api()

    upstreamgroups = get_ainode_all_conf()

    segmenterdeps = get_segmenter_deployments(name=name)

    for segmenterdep in segmenterdeps:
        if segmenterdep.spec.template.metadata.labels['group'] not in status:
            status[segmenterdep.spec.template.metadata.labels['group']] = {"deployments":   dict(),
                                                                           "ainodeconf":    get_ainode_conf(upstreamgroups,segmenterdep.spec.template.metadata.labels['group'])}

        if segmenterdep.metadata.name not in status[segmenterdep.spec.template.metadata.labels['group']]:
            status[segmenterdep.spec.template.metadata.labels['group']]["deployments"][segmenterdep.metadata.name]={"pods":dict(),
                                                                                                                    "inuse":get_deployment_inuse(status[segmenterdep.spec.template.metadata.labels['group']]["ainodeconf"],segmenterdep.metadata.name)}

        pods = clientcorev1.list_pod_for_all_namespaces(label_selector=get_selector_string_from_dep(segmenterdep))
        for pod in pods.items:
            status[segmenterdep.spec.template.metadata.labels['group']]["deployments"][segmenterdep.metadata.name]["pods"][pod.metadata.name] = {"version":    get_pod_version(pod),
                                                                                                                                                 "status":     get_pod_status(pod),
                                                                                                                                                 "ready":      get_pod_ready_container(pod)}
    return status

def render(name, status, window, newversion):
    window.clear()
    update_sizing(window)
    baseline = BASELINE_OFFSET
    if baseline >= 0:
        try:
            window.addstr(baseline, GROUPID_COLUMN_START,   "GROUPID")
        except curses.error:
            pass
        try:
            window.addstr(baseline, ID_COLUMN_START,        "ID")
        except curses.error:
            pass
        try:
            window.addstr(baseline, DEP_COLUMN_START,       "DEPLOYMENT")
        except curses.error:
            pass
        try:
            window.addstr(baseline, INUSE_COLUMN_START,     "INUSE")
        except curses.error:
            pass
        try:
            window.addstr(baseline, POD_COLUMN_START,       "POD")
        except curses.error:
            pass
        try:
            window.addstr(baseline, VERSION_COLUMN_START,   "VERSION")
        except curses.error:
            pass
        try:
            window.addstr(baseline, READY_COLUMN_START,     "READY")
        except curses.error:
            pass
        try:
            window.addstr(baseline, STATUS_COLUMN_START,    "STATUS")
        except curses.error:
            pass
    baseline += 1
    if baseline >= 0:
        try:
            window.addstr(baseline, GROUPID_COLUMN_START,   "-------")
        except curses.error:
            pass
        try:
            window.addstr(baseline, ID_COLUMN_START,        "--")
        except curses.error:
            pass
        try:
            window.addstr(baseline, DEP_COLUMN_START,       "----------")
        except curses.error:
            pass
        try:
            window.addstr(baseline, INUSE_COLUMN_START,     "-----")
        except curses.error:
            pass
        try:
            window.addstr(baseline, POD_COLUMN_START,       "---")
        except curses.error:
            pass
        try:
            window.addstr(baseline, VERSION_COLUMN_START,   "-------")
        except curses.error:
            pass
        try:
            window.addstr(baseline, READY_COLUMN_START,     "-----")
        except curses.error:
            pass
        try:
            window.addstr(baseline, STATUS_COLUMN_START,    "------")
        except curses.error:
            pass

    for group, value1 in status.items():
        for dep, value2 in value1["deployments"].items():
            for pod, value3 in value2["pods"].items():
                baseline += 1
                if baseline >= 0:
                    groupid = group.rsplit("-",1)[0]
                    groupid = groupid.split(f"{name}-",1)[-1]
                    podid = dep.split(f"{name}-{groupid}-",1)[-1]
                    podid = podid.split("-",1)[0]
                    try:
                        window.addstr(baseline, GROUPID_COLUMN_START, groupid)
                    except curses.error:
                        pass
                    try:
                        window.addstr(baseline, ID_COLUMN_START, podid)
                    except curses.error:
                        pass
                    try:
                        window.addstr(baseline, DEP_COLUMN_START, dep)
                    except curses.error:
                        pass

                    if value2['inuse'] == "yes":
                        try:
                            window.addstr(baseline, INUSE_COLUMN_START, value2['inuse'], curses.color_pair(3))
                        except curses.error:
                            pass
                    else:
                        try:
                            window.addstr(baseline, INUSE_COLUMN_START, value2['inuse'], curses.color_pair(1))
                        except curses.error:
                            pass
                    try:
                        window.addstr(baseline, POD_COLUMN_START, pod)
                    except curses.error:
                        pass
                    if newversion == "":
                        try:
                            window.addstr(baseline, VERSION_COLUMN_START, value3['version'])
                        except curses.error:
                            pass
                    elif newversion == value3['version']:
                        try:
                            window.addstr(baseline, VERSION_COLUMN_START, value3['version'], curses.color_pair(3))
                        except curses.error:
                            pass
                    else:
                        try:
                            window.addstr(baseline, VERSION_COLUMN_START, value3['version'], curses.color_pair(1))
                        except curses.error:
                            pass

                    if value3['ready'] == "1/1" or value3['ready'] == "2/2":
                        try:
                            window.addstr(baseline, READY_COLUMN_START, value3['ready'], curses.color_pair(3))
                        except curses.error:
                            pass
                    else:
                        try:
                            window.addstr(baseline, READY_COLUMN_START, value3['ready'], curses.color_pair(2))
                        except curses.error:
                            pass

                    if value3['status'] == "Running":
                        try:
                            window.addstr(baseline, STATUS_COLUMN_START, value3['status'], curses.color_pair(3))
                        except curses.error:
                            pass
                    elif value3['status'] == "Pending":
                        try:
                            window.addstr(baseline, STATUS_COLUMN_START, value3['status'], curses.color_pair(2))
                        except curses.error:
                            pass
                    else:
                        try:
                            window.addstr(baseline, STATUS_COLUMN_START, value3['status'], curses.color_pair(1))
                        except curses.error:
                            pass

    window.refresh()

async def interract(name, window, newversion):
    global active
    global BASELINE_OFFSET
    global status
    while active:
        keypressed = window.getch()
        while keypressed != -1:
            if keypressed == curses.KEY_DOWN:
                BASELINE_OFFSET -= 1
            elif keypressed == curses.KEY_UP:
                BASELINE_OFFSET += 1
            if keypressed == curses.KEY_PPAGE:
                BASELINE_OFFSET += 10
            elif keypressed == curses.KEY_NPAGE:
                BASELINE_OFFSET -= 10
            if BASELINE_OFFSET > 0:
                BASELINE_OFFSET = 0
            if status is not None:
                render(name, status, window, newversion)
            keypressed = window.getch()
        await asyncio.sleep(0.2)

async def display_status(name, window, newversion):
    global active
    global status
    while active:
        status = get_segmenter_status(name)
        render(name, status, window, newversion)
        await asyncio.sleep(1)

    window.clear()
    window.refresh()
    curses.endwin()


###########################################
### UPGRADE FUNCTIONS #####################
###########################################
def send_die_to_pod(pod):
    clientcorev1 = client.CoreV1Api()
    clientcorev1.connect_get_namespaced_pod_proxy_with_path(f"{pod.metadata.name}",f"{pod.metadata.namespace}","die")

def extract_name(image):
    return image.rsplit(":",1)[0], image.rsplit(":",1)[1]

async def put_deployment_replicas(deployment,replicas):
    clientappsv1 = client.AppsV1Api()
    clientcorev1 = client.CoreV1Api()
    patch = {"spec":{"replicas": replicas}}
    result = clientappsv1.patch_namespaced_deployment(deployment.metadata.name,deployment.metadata.namespace,patch)
    deployment = clientappsv1.read_namespaced_deployment(deployment.metadata.name,deployment.metadata.namespace)
    nbpods = deployment.spec.replicas
    ready = False
    died = list()
    while ready is False:
        ready = True
        pods = clientcorev1.list_namespaced_pod(namespace=deployment.metadata.namespace, label_selector=get_selector_string_from_dep(deployment))

        # If number of pods does not match the deployment, ready is false
        if len(pods.items) != nbpods:
            ready = False

        # If all container are not up, ready is false
        for pod in pods.items:
            podready = get_pod_ready_container(pod)
            if  podready != "1/1" and podready != "2/2":
                ready = False

            # Accelerate termination by sending die signal
            if get_pod_status(pod) == "Terminating":
                if podready == "1/1" or podready == "2/2":
                    if pod.metadata.name not in died:
                        died.append(pod.metadata.name)
                        send_die_to_pod(pod)

        await asyncio.sleep(1)

async def put_deployment_version(deployment,newversion):
    clientappsv1 = client.AppsV1Api()
    clientcorev1 = client.CoreV1Api()
    baseimage, _version = extract_name(deployment.spec.template.spec.containers[0].image)
    newimage = f"{baseimage}:{newversion}"
    patch = {
                "spec":
                {
                    "template":
                    {
                        "spec":
                        {
                            "containers":
                            [
                                {
                                    "name": deployment.spec.template.spec.containers[0].name,
                                    "image": newimage
                                }
                            ]
                        }
                    }
                }
            }
    result = clientappsv1.patch_namespaced_deployment(deployment.metadata.name,deployment.metadata.namespace,patch)
    deployment = clientappsv1.read_namespaced_deployment(deployment.metadata.name,deployment.metadata.namespace)
    nbpods = deployment.spec.replicas
    ready = False
    died = list()
    while ready is False:
        ready = True
        pods = clientcorev1.list_namespaced_pod(namespace=deployment.metadata.namespace, label_selector=get_selector_string_from_dep(deployment))
        # If number of pods does not match the deployment, ready is false
        if len(pods.items) != nbpods:
            ready = False

        # If all container are not up, ready is false
        for pod in pods.items:
            if pod.spec.containers[0].image != newimage:
                ready = False

            podready = get_pod_ready_container(pod)
            if  podready != "1/1" and podready != "2/2":
                ready = False

        await asyncio.sleep(1)

def put_ainode_conf(conf):
    clientcorev1 = client.CoreV1Api()
    services = clientcorev1.list_service_for_all_namespaces(label_selector="app.kubernetes.io/name=segmenter-ainode,app.quortex.io/type=ainode")
    if len(services.items):
        service = services.items[0]
        path_params = {"name": f"{service.metadata.name}:api",
                       "namespace": service.metadata.namespace,
                       "path": f"1.0/upstreamgroup/{conf['uuid']}"}
        _response = clientcorev1.api_client.call_api('/api/v1/namespaces/{namespace}/services/{name}/proxy/{path}', 'PUT',
                                                     path_params,
                                                     [],
                                                     {"Accept": "*/*","Content-Type":"application/json"},
                                                     body=conf,
                                                     post_params=[],
                                                     files={},
                                                     response_type='str',
                                                     auth_settings=["BearerToken"],
                                                     async_req=False,
                                                     _return_http_data_only=True,
                                                     _preload_content=True,
                                                     _request_timeout=None,
                                                     collection_formats={})

async def upgrade_deployment(deployment, ainodeconfs, newversion, overbw):
    # Check if deployment is correct version
    _baseimage, version = extract_name(deployment.spec.template.spec.containers[0].image)
    if version == newversion:
        return

    # Check if deployment is used, for each use deactivate upstream before update
    svcname = deployment.metadata.name.split("deployment")[0]+"service"
    modifiedconfs = list()
    newconfs = list()
    nbupstream = 0
    for conf in ainodeconfs:
        newupstreams = list()
        updateconf = False
        for upstream in conf["upstream"]:
            if svcname not in upstream["address"]:
                newupstreams.append(upstream)
            else:
                updateconf = True
        if updateconf is True:
            newconf = deepcopy(conf)
            nbupstream = len(conf["upstream"])
            newconf["upstream"] = newupstreams
            newconfs.append(newconf)
            modifiedconfs.append(conf)

    # Check if deployment is used by checking the number of conf where it is used
    if len(newconfs):
        notused = False
    else:
        notused = True

    # Set replicas to zero to avoid overbandwith consumption
    # Conditions one of following:
    # 1: overbandwidth is not allowed
    # 2: number of upstream must be != 1
    # 3: the deployment is not used
    if overbw is False or nbupstream != 1 or notused is True:
        nbreplicas = deployment.spec.replicas
        await put_deployment_replicas(deployment,0)

    # Upgrade version of deployment
    await put_deployment_version(deployment,newversion)

    # Reset replicas to nominal value
    if overbw is False or nbupstream != 1 or notused is True:
        await put_deployment_replicas(deployment,nbreplicas)

    await asyncio.sleep(1)

async def upgrade_version(name, newversion, groupids, overbw, parallel):
    deployments = get_segmenter_deployments(name=name,groupids=groupids)
    ainodeconfs = get_ainode_all_conf()

    if len(deployments) == 0:
        return

    if parallel is True:
        futures1 = list()
        futures2 = list()
        futures3 = list()
        deplist1 = list()
        deplist2 = list()
        deplist3 = list()
        for dep in deployments:
            groupname = get_group(dep)
            if groupname not in deplist1:
                deplist1.append(groupname)
                futures1.append(upgrade_deployment(dep, ainodeconfs, newversion, overbw))
            elif groupname not in deplist2:
                deplist2.append(groupname)
                futures2.append(upgrade_deployment(dep, ainodeconfs, newversion, overbw))
            elif groupname not in deplist3:
                deplist3.append(groupname)
                futures3.append(upgrade_deployment(dep, ainodeconfs, newversion, overbw))
        if len(futures1):
            await asyncio.gather(*futures1)
        if len(futures2):
            await asyncio.gather(*futures2)
        if len(futures3):
            await asyncio.gather(*futures3)
    else:
        for dep in deployments:
            await upgrade_deployment(dep, ainodeconfs, newversion, overbw)


if __name__ == '__main__':

    # Parse argument
    parser = argparse.ArgumentParser()
    required = parser.add_argument_group('required arguments')
    required.add_argument("-v", "--version",        default="",             help="The new segmenter version to update")
    required.add_argument("-n", "--name",           default="segmenter",    help="Specify the basename of the segmenters")
    required.add_argument("-d", "--display",        default=False,          help="Display ongoing update",                  action='store_true')
    required.add_argument("-u", "--upgrade",        default=False,          help="Do upgrade",                              action='store_true')
    required.add_argument("-o", "--overbandwidth",  default=False,          help="Allow overbandwidth for mono segmenter",  action='store_true')
    required.add_argument("-p", "--parallel",       default=False,          help="Allow parallel update of segmenters",     action='store_true')
    required.add_argument("-g", "--group",          default=None,           help="Specify the list of group to update",     nargs='+')


    # Get arguments
    args = parser.parse_args()

    # Load current kube config
    try:
        config.load_kube_config()
    except config.config_exception.ConfigException:
        print("Missing kube config file")
        sys.exit(-1)

    # If upgrade is enable, version is mandatory
    if args.version == "" and args.upgrade:
        print("Cannot upgrade without version")
        sys.exit(-1)

    futures = list()

    # If display enable, add display coroutine
    if args.display:
        screen = curses.initscr()
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_RED, -1)
        curses.init_pair(2, curses.COLOR_YELLOW, -1)
        curses.init_pair(3, curses.COLOR_GREEN, -1)
        curses.curs_set(0)
        curses.noecho()
        window = curses.newwin(20, 10, 0, 0)
        window.keypad(True)
        window.nodelay(True)
        futures.append(interract(name=args.name, window=window, newversion=args.version))
        futures.append(display_status(name=args.name, window=window, newversion=args.version))

    # If upgrade enabled, add upgrade coroutine
    if args.upgrade:
        futures.append(upgrade_version(name=args.name, newversion=args.version, groupids=args.group, overbw=args.overbandwidth, parallel=args.parallel))

    # Start coroutines
    try:
        loop = asyncio.get_event_loop()
        loop.run_until_complete(asyncio.gather(*futures))
    except KeyboardInterrupt:
        active = False
        if args.display:
            loop.run_until_complete(display_status(name=args.name, window=window,newversion=args.version))
        print("End upgrade...")
