# Catalog (~/.practices/spaces) -> JSON for the map prototype. Names and structure only: no
# keys, no endpoint addresses, no notes. Throwaway (PLAN step 5: the map is designed on a mock-up).
require "yaml"
require "json"

home = File.expand_path(ARGV[0] || "~/.practices/spaces")
out = { spaces: [], projects: [], services: [], links: [], conditions: [] }
load_yaml = ->(path, default) { File.exist?(path) ? (YAML.safe_load(File.read(path)) || default) : default }

Dir.children(home).sort.each do |space|
  dir = File.join(home, space)
  next unless File.exist?(File.join(dir, "space.yaml"))
  out[:spaces] << { id: space, name: load_yaml.(File.join(dir, "space.yaml"), {})["name"] || space }
  load_yaml.(File.join(dir, "conditions.yaml"), []).each { |c| out[:conditions] << c.slice("id", "name", "hint").merge("space" => space) }
  Dir.glob(File.join(dir, "projects", "*", "project.yaml")).sort.each do |pf|
    pid = File.basename(File.dirname(pf))
    p = load_yaml.(pf, {})
    out[:projects] << { id: pid, space: space, name: p["name"] || pid, parent: p["parent"], description: p["description"],
                        repos: (p["repos"] || []).map { |r| { repo: r["repo"], role: r["role"] } },
                        folders: (p["folders"] || []).map { |f| f["name"] } }
    Dir.glob(File.join(File.dirname(pf), "services", "*", "service.yaml")).sort.each do |sf|
      sid = File.basename(File.dirname(sf))
      s = load_yaml.(sf, {})
      practices = Dir.glob(File.join(File.dirname(sf), "practices", "*.py")).map { |f| File.basename(f, ".py") }.sort
      out[:services] << { id: sid, project: pid, space: space, name: s["name"] || sid, kind: s["kind"] || "other",
                          description: s["description"], tags: s["tags"] || [], repo: s["repo"],
                          aliases: (s["aliases"] || []).reject { |a| a =~ /\A\d+\.\d+\.\d+\.\d+/ },
                          envs: s["envs"] || [], requires: s["requires"] || [], guards: s["guards"] || [],
                          endpoints: (s["endpoints"] || []).map { |e| { id: e["id"], label: e["label"], requires: e["requires"] || [] } },
                          practices: practices }
      load_yaml.(File.join(File.dirname(sf), "links.yaml"), []).each do |l|
        out[:links] << { from: sid }.merge(l.slice("to", "endpoint", "env", "via", "what", "access", "why", "practice", "origin"))
      end
    end
  end
end
puts JSON.generate(out)
