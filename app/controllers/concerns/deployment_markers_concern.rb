module DeploymentMarkersConcern
  def populate_deployment_markers
    return unless @time_range&.window

    @deployment_markers = RailsPulse::Deployment
      .for_range(@time_range.window.start_time, @time_range.window.end_time)
      .map(&:to_chart_marker)
  end
end
