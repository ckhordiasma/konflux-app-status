import sys
import re
import json

class bcolors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

components = {name: True for name in sys.argv[1].split("\n")}
pipelines = json.loads(sys.argv[2])
most_recent_pipelines = {}
for entry in pipelines:
  pipeline, status = entry["pipeline"], entry["status"]
  # print(pipeline)
  for component in components:
    if re.match(component, pipeline):
      # print(f"{pipeline} matches {component}")
      most_recent_pipelines[component] = [pipeline, status]
      components.pop(component) 
      break

for component in most_recent_pipelines:
  pipeline, status = most_recent_pipelines[component]
  if re.match('Failed',status):
    status_color = bcolors.FAIL
  elif re.match('Running',status):
    status_color = bcolors.OKBLUE
  else:
    status_color = bcolors.OKGREEN
  print(f"{pipeline}\t{status_color}{status}{bcolors.ENDC}")

if len(components) != 0:
  print("some components were not found in pipeline history:")
  print(",".join([c for c in components]))
