require "yaml"

module LogViz
  # Minimal reader for `.boukensha/settings.yaml`'s `tasks:` block — lets the
  # content-fact background classification "subtask" (ContentFact + WorldMap's
  # worker thread) be configured the same way a real agent task is
  # (`tasks.player.provider`/`.model` in `Boukensha::Tasks::Base`/`Config`),
  # per docs/plans/observability/room_world_inspector.md:
  #
  #   tasks:
  #     content_fact:
  #       provider: ollama
  #       model: gemma4
  #       host: http://localhost:11434   # optional; OLLAMA_HOST env still works too
  #
  # This is a read-only, one-way dependency on a file the agent side also
  # reads — the same posture `log_viz` already has toward `.jsonl` session
  # logs (reads a format/file it doesn't own, never writes to it). It does
  # NOT depend on the `boukensha` gem/code — `week2_observability/ruby/
  # 13_room_inspector` and `log_viz` are still two separate Ruby programs
  # that happen to agree on one YAML file's shape.
  #
  # Unlike `Boukensha::Tasks::Base#provider`/`#model` (which raise if a
  # task's settings are missing — Player has no sensible default),
  # content_fact is a best-effort background feature: no settings.yaml, no
  # `tasks.content_fact` block, or a missing key all fall back to a
  # hardcoded default rather than raising. log_viz must keep working with
  # zero configuration — same fail-soft posture as the rest of this feature
  # (an unreachable Ollama daemon already degrades to `kind: "unknown"`
  # rather than blocking ingestion; missing settings.yaml is the same kind
  # of "degrade, don't break" case).
  #
  # `host` is deliberately readable from settings.yaml too (not just
  # `OLLAMA_HOST`) since the WSL-vs-Windows-Ollama networking question that
  # motivated this file is exactly the kind of thing you don't want to
  # re-export in every shell session. `OLLAMA_HOST` still wins if set,
  # matching how the agent's own `ollama_host:` argument is an explicit
  # override, not something `tasks.player` configures either — same
  # asymmetry preserved on purpose, not an oversight.
  module Settings
    DEFAULT_PROVIDER = "ollama"
    DEFAULT_MODEL    = "gemma4"
    DEFAULT_HOST     = "http://localhost:11434"

    def self.boukensha_dir(sessions_dir)
      File.dirname(sessions_dir)
    end

    def self.load(sessions_dir)
      path = File.join(boukensha_dir(sessions_dir), "settings.yaml")
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue Psych::SyntaxError, IOError => e
      warn "[LogViz::Settings] couldn't read #{path} (#{e.message}) — using content_fact defaults"
      {}
    end

    def self.content_fact_provider(sessions_dir)
      content_fact(sessions_dir, "provider") || DEFAULT_PROVIDER
    end

    def self.content_fact_model(sessions_dir)
      content_fact(sessions_dir, "model") || DEFAULT_MODEL
    end

    # ENV["OLLAMA_HOST"] wins over settings.yaml — see the class comment on
    # why the host specifically keeps this precedence, unlike provider/model.
    def self.content_fact_host(sessions_dir)
      ENV["OLLAMA_HOST"] || content_fact(sessions_dir, "host") || DEFAULT_HOST
    end

    def self.content_fact(sessions_dir, key)
      dig(load(sessions_dir), "content_fact", key)
    end
    private_class_method :content_fact

    def self.dig(settings, task, key)
      tasks = fetch(settings, "tasks")
      return nil unless tasks.is_a?(Hash)

      node = fetch(tasks, task)
      return nil unless node.is_a?(Hash)

      fetch(node, key)
    end
    private_class_method :dig

    def self.fetch(hash, key)
      hash[key] || hash[key.to_sym]
    end
    private_class_method :fetch
  end
end
