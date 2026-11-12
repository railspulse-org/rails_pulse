module RailsPulse
  module BreadcrumbsHelper
    # Maps singularized path segments to their actual model class names
    # when the default classify convention doesn't match
    SEGMENT_CLASS_OVERRIDES = {
      "run" => "JobRun",
      "exception" => "ExceptionGroup",
      "occurrence" => "ExceptionOccurrence"
    }.freeze

    def breadcrumbs
      # Get the engine's mount point segments
      mount_segments = RailsPulse::Engine.routes.find_script_name({}).split("/").reject(&:empty?)

      # Split the full path and remove empty segments
      path_segments = request.path.split("/").reject(&:empty?)

      # Find where the mount point segments end in the request path
      mount_end_index = nil
      (0..path_segments.length - mount_segments.length).each do |i|
        if path_segments[i, mount_segments.length] == mount_segments
          mount_end_index = i + mount_segments.length - 1
          break
        end
      end

      # If we can't find the mount point or it's the last segment, return empty
      return [] if mount_end_index.nil? || mount_end_index == path_segments.length - 1

      # Only keep segments after the mount point
      path_segments = path_segments[(mount_end_index + 1)..-1]

      # Build the engine root path directly from mount segments (avoids relying on named route helper).
      # Served at "/" (standalone server, or a host that mounts the engine at root) the prefix
      # is empty, not "/": segments are appended as "/#{segment}", and "/" + "/queries" would be
      # "//queries" — a protocol-relative URL that browsers resolve to a host called "queries".
      engine_root = mount_segments.empty? ? "" : "/" + mount_segments.join("/")

      # Start with the Home link
      crumbs = [ {
        title: "Home",
        path: engine_root.empty? ? "/" : engine_root,
        current: path_segments.empty?
      } ]

      return crumbs if path_segments.empty?

      current_path = engine_root

      path_segments.each_with_index do |segment, index|
        current_path += "/#{segment}"

        # Convert segment to a more readable format
        title = if segment =~ /^\d+$/
          # If it's a numeric ID, try to find a title from the resource
          resource_name = path_segments[index - 1]&.singularize
          # Look up the class in the RailsPulse namespace, with override map for non-conventional names
          class_name = SEGMENT_CLASS_OVERRIDES[resource_name] || resource_name&.classify
          resource_class = "RailsPulse::#{class_name}".safe_constantize
          if resource_class
            resource = resource_class.find(segment)
            # Try to_breadcrumb first, fall back to to_s
            resource.try(:to_breadcrumb) || resource.to_s
          else
            segment
          end
        else
          segment.titleize
        end

        is_last = index == path_segments.length - 1

        # For nested resources, if this is a collection name followed by an ID,
        # link to the parent resource's show page instead of the nested index
        breadcrumb_path = if !is_last &&
                            segment !~ /^\d+$/ &&
                            index > 0 &&
                            path_segments[index - 1] =~ /^\d+$/ &&
                            path_segments[index + 1] =~ /^\d+$/
          # This is a nested collection (e.g., /jobs/5/runs/291)
          # Link to parent show page (e.g., /jobs/5)
          path_segments[0..index-1].inject(engine_root) { |path, seg| path + "/#{seg}" }
        else
          current_path
        end

        crumbs << {
          title: title,
          path: breadcrumb_path,
          current: is_last
        }
      end

      crumbs
    end

    def page_title
      crumbs = breadcrumbs
      return rails_pulse_name if crumbs.empty?

      current = crumbs.last
      if current[:current] && current[:title] != "Home"
        "#{current[:title]} — #{rails_pulse_name}"
      else
        rails_pulse_name
      end
    end

    # "Rails Pulse", followed on a central by the application being shown,
    # so two applications' dashboards cannot be mistaken for each other.
    def rails_pulse_name
      application = RailsPulse::Central.current_application
      application ? "Rails Pulse · #{application}" : "Rails Pulse"
    end
  end
end
