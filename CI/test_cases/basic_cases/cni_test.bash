#!/bin/bash
#
# attributes: isulad cri cni
# concurrent: NA
# spend time: 10

curr_path=$(dirname $(readlink -f "$0"))
data_path=$(realpath $curr_path/criconfigs)
source ../helpers.bash

function do_pre()
{
    cp /etc/isulad/daemon.json /etc/isulad/daemon.bak
    sed -i "s#\"pod-sandbox-image\": \"\"#\"pod-sandbox-image\": \"rancher/pause-amd64:3.0\"#g" /etc/isulad/daemon.json

    init_cni_conf $data_path
    if [ $? -ne 0 ]; then
        ERROR "Failed to init cni config"
        TC_RET_T=$(($TC_RET_T+1))
        return $TC_RET_T
    fi
}

function do_post()
{
    cp -f /etc/isulad/daemon.bak /etc/isulad/daemon.json
    stop_isulad_without_valgrind
    start_isulad_without_valgrind
}

function do_test_help()
{
    INFO "this is $0 do_test"

    crictl images | grep busybox
    if [ $? -ne 0 ]; then
        ERROR "Failed to find busybox image"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    sid=`crictl runp ${data_path}/sandbox-config.json`
    if [ $? -ne 0 ]; then
        ERROR "Failed to run sandbox"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    spid=`isula inspect -f '{{json .State.Pid}}' $sid`
    nsenter -t $spid -n ifconfig eth0
    if [ $? -ne 0 ];then
        ERROR "Sandbox network config failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    cid=`crictl create $sid ${data_path}/container-config.json ${data_path}/sandbox-config.json`
    if [ $? -ne 0 ];then
        ERROR "create container failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    crictl start $cid
    if [ $? -ne 0 ];then
        ERROR "start container failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    # check whether container use pod network namespace
    pod_pid=`isula inspect -f '{{json .State.Pid}}' $sid`
    pod_net_ns_id=`ls -l /proc/${pod_pid}/ns/net | awk -F[ '{print $2}' |awk -F] '{print $1}'`
    con_pid=`isula inspect -f '{{json .State.Pid}}' $cid`
    con_net_ns_id=`ls -l /proc/${con_pid}/ns/net | awk -F[ '{print $2}' |awk -F] '{print $1}'`

    if [ "$pod_net_ns_id" != "$con_net_ns_id" ];then
        ERROR "Pod and container use different network namespace"
        nsenter -t $pod_pid -n ifconfig eth0
        nsenter -t $con_pid -n ifconfig eth0
        TC_RET_T=$(($TC_RET_T+1))
    fi
    nsenter -t $pod_pid -n ifconfig eth0 | grep "$1"
    if [ $? -ne 0 ];then
        ERROR "expect ip: $1, get: "
        nsenter -t $pod_pid -n ifconfig eth0
        TC_RET_T=$(($TC_RET_T+1))
    fi

    crictl stop $cid
    if [ $? -ne 0 ];then
        ERROR "stop container failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    crictl rm $cid
    if [ $? -ne 0 ];then
        ERROR "stop container failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    crictl stopp $sid
    if [ $? -ne 0 ];then
        ERROR "stop sandbox failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    crictl rmp $sid
    if [ $? -ne 0 ];then
        ERROR "rm sandbox failed"
        TC_RET_T=$(($TC_RET_T+1))
    fi

    return $TC_RET_T
}

function default_cni_config()
{
    do_test_help "10\.1\."
}

function new_cni_config()
{
    cp ${data_path}/bridge.json /etc/cni/net.d/
    sync;sync;
    tail $ISUALD_LOG
    # wait cni updated
    s=`date "+%s"`
    for ((i=0;i<30;i++)); do
        sleep 1
        cur=`date "+%s"`
        let "t=cur-s"
        if [ $t -gt 6 ];then
            break
        fi
    done
    tail $ISUALD_LOG
    do_test_help "10\.2\."
}

ret=0

do_pre
if [ $? -ne 0 ];then
    let "ret=$ret + 1"
fi

default_cni_config
if [ $? -ne 0 ];then
    let "ret=$ret + 1"
fi

new_cni_config
if [ $? -ne 0 ];then
    let "ret=$ret + 1"
fi

do_post

show_result $ret "cni base test"
