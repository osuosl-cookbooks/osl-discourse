require 'date'

module OslDiscourse
  module Cookbook
    module Helpers
      WEEKDAY_NAMES = %w(Sun Mon Tue Wed Thu Fri Sat).freeze

      # Convert a (weekday, hour, minute) in a named timezone to its UTC
      # equivalent so it can be written into a cron file on a UTC-hosted box.
      # Returns { minute:, hour:, weekday: } with weekday as a 3-letter
      # abbreviation accepted by cron.
      #
      # Uses Ruby stdlib + system tzdata (/usr/share/zoneinfo) via ENV['TZ']
      # rather than the tzinfo gem, which isn't bundled with Cinc Client.
      #
      # `today:` is injectable for deterministic testing across DST states.
      # Note: the result is only correct until the next DST transition in the
      # target timezone; subsequent chef-client converges will recompute and
      # update the cron entry.
      def discourse_cron_utc(weekday, hour, minute, time_zone, today: Date.today)
        weekday_num =
          if weekday.is_a?(Integer) || weekday.to_s =~ /\A\d+\z/
            weekday.to_i % 7
          else
            idx = WEEKDAY_NAMES.index { |n| n.casecmp?(weekday.to_s) }
            raise ArgumentError, "invalid weekday: #{weekday.inspect}" unless idx
            idx
          end

        target = today + ((weekday_num - today.wday) % 7)

        prev_tz = ENV['TZ']
        begin
          ENV['TZ'] = time_zone
          utc_time = Time.local(target.year, target.month, target.day, hour.to_i, minute.to_i, 0).utc
        ensure
          ENV['TZ'] = prev_tz
        end

        {
          minute: utc_time.min,
          hour: utc_time.hour,
          weekday: WEEKDAY_NAMES[utc_time.wday],
        }
      end

      def discourse_shared_path(container_name, shared_path_name = nil)
        shared_path_name || container_name
      end

      # True if a container with the given name exists (running or stopped).
      # Uses the docker-api gem (loaded transitively via osl-docker → docker)
      # rather than shelling out to `docker ps`. Returns false on any docker
      # error so the caller treats it as "needs first-time install".
      def discourse_container_exists?(container_name)
        require 'docker'
        begin
          Docker::Container.get(container_name)
          true
        rescue Docker::Error::NotFoundError
          false
        rescue StandardError
          false
        end
      rescue LoadError
        # docker-api gem unavailable (this resource pulls in osl-docker so this
        # is mostly a defensive guard); treat as "no container", let the caller
        # attempt the rebuild and fail visibly if docker really isn't usable.
        false
      end

      def discourse_container_yml(launcher_dir, container_name)
        "#{launcher_dir}/containers/#{container_name}.yml"
      end

      def discourse_realip_template(launcher_dir)
        "#{launcher_dir}/templates/web.realip.template.yml"
      end

      def discourse_rebuild_script
        '/usr/local/sbin/discourse-rebuild'
      end

      def discourse_rebuild_command(container_name, docker_args, skip_mac_address)
        args = [container_name, '--docker-args', %("#{docker_args}")]
        args << '--skip-mac-address' if skip_mac_address
        "#{discourse_rebuild_script} #{args.join(' ')}"
      end
    end
  end
end
Chef::DSL::Recipe.include ::OslDiscourse::Cookbook::Helpers
Chef::Resource.include ::OslDiscourse::Cookbook::Helpers
