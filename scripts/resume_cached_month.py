#!/usr/bin/env python3
"""Drain an already exported month without requesting new Photos access."""
import argparse,json,signal,sys
import cloud_index as cloud
p=argparse.ArgumentParser();p.add_argument('--month',required=True);a=p.parse_args()
def stop(*_):cloud.STOP=True
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
while not cloud.STOP:
    cloud.run(a.month,35,1,max_new=100,global_budget=35)
    state=json.loads((cloud.BASE/'cloud-index'/a.month/'progress.json').read_text())
    if state['phase']!='batch_complete':break
