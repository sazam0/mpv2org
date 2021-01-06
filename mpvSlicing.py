#!/usr/bin/env python3

import subprocess
from pathlib import Path
import os
from threading import Thread, BoundedSemaphore, Lock
import argparse
from datetime import datetime
import time
import re
from functools import partial
from decouple import config

class MyThread(Thread):
    def __init__(self,nthreads):
        self.threadLimiter = BoundedSemaphore(nthreads)
        self.executing=[]
        self.done=[]
        self.lock=Lock()

    def run(self,cmd):
        self.threadLimiter.acquire()
        try:
            #print("executing: ",self.executing)
            # print(id," : started")
            self.Executemycode(cmd)
        finally:
            # print(id," : ended")

            self.lock.acquire()

            self.done.append(cmd)
            self.executing.remove(cmd)

            self.lock.release()
            self.threadLimiter.release()

            #print("done: \t\t\t\t\t",self.done)

    def Executemycode(self,cmd):
        self.lock.acquire()
        self.executing.append(cmd)
        self.lock.release()

        result=subprocess.run(cmd,shell=True,check=True,
                capture_output=True,text=True)

        return 0

    def executedList(self):
        return self.done

def fileIO(fromFile,mode,txt):
    if(mode == 'r'):
        with open(fromFile, mode) as target:
            tmp=[i for i in target.readlines() if len(i)>1] # escape the empty lines
        return tmp
    if(mode == 'a'):
        with open(fromFile,mode) as target:
            target.write(txt)
        return 0
    if(mode == 'w'):
        with open(fromFile,mode) as target:
            target.write(txt)
        return 0
    return 0

def ffmpegExec(gpu,thrd,vidCmdList,imgCmdList,cmdList):

    vidThreads=[Thread(target=thrd.run, args=(cmd,)) for cmd in vidCmdList]
    imgThreads=[Thread(target=thrd.run, args=(cmd,)) for cmd in imgCmdList]

    if(len(imgThreads)>0):
        print("processing imgaes")
        for thread in imgThreads:
            thread.start()
        for thread in imgThreads:
            thread.join()
    else:
        print("no image to process in '{img}'".format(img=cmdList['img']))

    if(len(vidThreads)>0):
        print("processing videos")
        for thread in vidThreads:
            thread.start()
        for thread in vidThreads:
            thread.join()
    else:
        print("no video to process in '{selectedFile}'"
            .format(selectedFile="{gpu}"
                .format(gpu=cmdList['gpu']) if gpu else "{cpu}".format(cpu=cmdList['cpu'])))

    print("All done")

    return 0

def clearCmd(thrd,fileDir,cmdList,archFile):

    ipTemplate=re.compile("\-i\s.*mp4\s-")
    opTemplate=re.compile("\s/home/.*(?:mp4|jpg|png)")

    log="\n\n["+str(datetime.now().strftime("%d/%m/%Y_%H:%M:%S"))+"]\n\n"

    ipRelativePath=lambda x: ipTemplate.sub("-i {input}/"+ipTemplate.findall(x)[0].split('/')[-1],x)
    opRelativePath=lambda x: opTemplate.sub(" {output}/"+opTemplate.findall(x)[0].split('/')[-1],x)

    relativePath=lambda x: opRelativePath(ipRelativePath(x)) if (opTemplate.search(ipRelativePath(x))!= None) else ipRelativePath(x)

    fileIO(fromFile=fileDir+"/{arch}".format(arch=archFile),mode='a',
        txt=log+'\n'.join(map(relativePath,thrd.executedList())))

    print("cleaning 'mpv' generated files :: '{cmdList}'"
        .format(cmdList=', '.join(list(cmdList.values()))))

    _=list(map(partial(fileIO,mode='w',txt=''),
            [fileDir+'/'+i for i in list(cmdList.values())]))

    return 0


def formatCmd(cmdTxt, ipDir, opDir):
    if("{input}" in cmdTxt):
        print("'input' directory not assigned in 'ffmpeg' command, setting directory to: {ipDir}".format(ipDir=ipDir))
        cmdTxt=cmdTxt.format(input=ipDir)
    else:
        print("'input' directory is already assigned in 'ffmpeg' command")
    if("{output}" in cmdTxt):
        print("'output' directory not assigned in 'ffmpeg' command, setting directory to: {opDir}".format(opDir=opDir))
        cmdTxt=cmdTxt.format(output=opDir)
    else:
        print("'output' directory is already assigned in 'ffmpeg' command")
    return cmdTxt


def formatDir(txt):
    if(txt.startswith("~/")):
        txt='/'.join([str(Path.home()),txt[2:]])
    elif(txt.startswith('./')):
        txt='/'.join([str(Path.cwd()),txt[2:]])
    else:
        pass

    return txt

def initialize(gpu,nthreads,fileDir,ipDir,opDir,cmdList,archFile,archCmd):
    fromImgFile=cmdList['img']
    if(gpu):
        fromVidFile=cmdList['gpu']
        # threads highere than 3 creates blank file, my gpu can handle at most 3 ffmpeg threads
        # nthreads=3 if (nthreads<3 or nthreads>3) else nthreads
        print("Executing on gpu with :: {nthreads} threads".format(nthreads=nthreads))
    else:
        # I am using threads in ffmpeg, so running only one file at once
        nthreads=1
        fromVidFile=cmdList['cpu']
        print("Executing on cpu")

    fileDir=formatDir(fileDir)
    # opDir=formatDir(opDir)
    # ipDir=formatDir(ipDir)

    if(archCmd != "-1"):
        tmpVidCmd,tmpImgCmd=parseArch(archCmd,archFile,fileDir)
    else:
        tmpVidCmd=fileIO(fromFile='/'.join([fileDir,fromVidFile]),mode='r',txt='')
        tmpImgCmd=fileIO(fromFile='/'.join([fileDir,fromImgFile]),mode='r',txt='')

    partialFormatCmd=partial(formatCmd,ipDir=formatDir(ipDir),opDir=formatDir(opDir))

    vidCmdList=list(map(partialFormatCmd,tmpVidCmd))
    imgCmdList=list(map(partialFormatCmd,tmpImgCmd))

    # vidCmdList=[i.format(output=opDir)  for i in fileIO(fromFile='/'.join([fileDir,fromVidFile]),mode='r',txt='')]
    # imgCmdList=[i.format(output=opDir)  for i in fileIO(fromFile='/'.join([fileDir,fromImgFile]),mode='r',txt='')]

    return [nthreads,vidCmdList,imgCmdList,fileDir]

def check_cuda_version():
    flag=False
    try:
        bash_command = "nvcc --version"
        process = subprocess.Popen(
            bash_command.split(), stdout=subprocess.PIPE)
        out = process.communicate()[0]
        flag=True if "nvcc: NVIDIA (R) Cuda compiler driver" in str(out) else False

    except OSError as e:
        pass
    return flag

def parseArch(archCmd,archFile,fileDir):
    splitFormat=re.compile("\[\d\d\/\d\d\/\d\d\d\d\_\d\d:\d\d:\d\d\]\n")
    tagFormat=re.compile("\[\d\d\/\d\d\/\d\d\d\d\_\d\d:\d\d:\d\d\]")
    imgFormat=re.compile("\.(?:jpg|png)")

    if(not archCmd.startswith("[")):
        archCmd="["+archCmd
    if(not archCmd.endswith("]")):
        archCmd+="]"

    if(tagFormat.match(archCmd) != None):
        pass
    else:
        print("'archieve' command do not follow the specified format")
        exit()

    tmp=fileIO(fromFile=fileDir+"/{arch}".format(arch=archFile),mode='r',txt='')
    tmp=''.join(tmp)
    splitted=tmp.split(archCmd)[1]
    splitted=splitFormat.split(splitted)[0].split('\n')

    tmpVidCmd=[]
    tmpImgCmd=[]
    skipBlankLines=lambda x: tmpImgCmd.append(x) if(imgFormat.search(x)!= None) else tmpVidCmd.append(x)

    _=list(map(skipBlankLines,[i for i in splitted if(len(i.strip())>1)]))

    return [tmpVidCmd,tmpImgCmd]

def parseArgs(cmdList):
    parser=argparse.ArgumentParser()

    parser.add_argument('--arch', '-a', type=str,default='-1',metavar='dd/mm/yyyy_hh/mm/ss',
        help="if set, the commands from matched tag from archieve file will be executed")
    parser.add_argument('--ip', '-i',type=str,default=config('ip'), metavar='[dir]',
        help="input directory for mpv generated files for ffmpeg extraction")
    parser.add_argument('--op', '-o',type=str,default=config('op'), metavar='[dir]',
        help="output directory for ffmpeg generated sliced files")
    parser.add_argument('--file', '-f',type=str, default=config('file'), metavar='[dir]',
        help="directory of mpv generated '{cmdList}' files"
        .format(cmdList=', '.join(list(cmdList.values()))))
    parser.add_argument('--nthreads', '-n', type=int, default=config('nthreads'),
        metavar='[int]', help="number of pc threads(semaphore) to be used")

    return parser.parse_args()



def main():
    """
    if gpu: 3 threads
        video on gpu, img on cpu
    if cpu: 1 thread
        video on cpu, img on cpu
    """
    tic=time.perf_counter()

    cmdList={
    "cpu":"cpuList.dat",
    "gpu":"gpuList.dat",
    "img":"imgList.dat"
    }

    archFile="log/archieve.log"

    inputs=parseArgs(cmdList)
    gpu=check_cuda_version()

    nthreads,vidCmdList,imgCmdList,fileDir=initialize(gpu=gpu,nthreads=inputs.nthreads,
        fileDir=inputs.file,ipDir=inputs.ip,opDir=inputs.op,cmdList=cmdList,
        archFile=archFile,archCmd=inputs.arch)

    thrd=MyThread(nthreads)
    ffmpegExec(gpu,thrd,vidCmdList,imgCmdList,cmdList)
    clearCmd(thrd,fileDir,cmdList,archFile)

    toc=time.perf_counter()
    # convert seconds to minutes
    print("elapsed time: {elapsed_time:2.4f} min".format(elapsed_time=(toc-tic)/60))

    return 0

if __name__ == '__main__':
    main()
