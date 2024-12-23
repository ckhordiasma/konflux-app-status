import sys
import re
import json


components = {name: True for name in sys.argv[1].split("\n")}
pipelines = json.loads(sys.argv[2])
most_recent_pipelines = {}
for entry in pipelines:
  pipeline, status = entry["pipeline"], entry["status"]
  # print(pipeline)
  for component in components:
    if re.match(component, pipeline):
      # print(f"{pipeline} matches {component}")
      most_recent_pipelines[component] = {"pipeline": pipeline, "status":status}
      components.pop(component) 
      break


print(json.dumps(most_recent_pipelines))

if len(components) != 0:
  raise ValueError(f"some components were not found in pipeline history:{",".join([c for c in components])}")
