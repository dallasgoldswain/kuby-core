# typed: false
require 'kube-dsl'

module Kuby
  module Plugins
    module RailsApp
      class Assets < ::Kuby::Plugin
        extend ::KubeDSL::ValueFields

        ROLE = 'assets'.freeze
        NGINX_IMAGE = 'nginx:1.9-alpine'.freeze
        NGINX_PORT = 8082
        NGINX_MOUNT_PATH = '/usr/share/nginx/assets'.freeze
        RAILS_MOUNT_PATH = '/usr/share/assets'.freeze

        value_fields :asset_url, :packs_url, :asset_path

        def configure(&block)
          instance_eval(&block)
        end

        def configure_ingress(ingress, hostname)
          spec = self

          ingress.spec.rule do
            host hostname

            http do
              path do
                path spec.asset_url

                backend do
                  service_name spec.service.metadata.name
                  service_port spec.service.spec.ports.first.port
                end
              end

              path do
                path spec.packs_url

                backend do
                  service_name spec.service.metadata.name
                  service_port spec.service.spec.ports.first.port
                end
              end
            end
          end
        end

        def copy_task
          @copy_task ||= AssetCopyTask.new(
            from: asset_path, to: RAILS_MOUNT_PATH
          )
        end

        def service(&block)
          spec = self

          @service ||= KubeDSL.service do
            metadata do
              name "#{spec.selector_app}-#{spec.role}-svc"
              namespace spec.namespace.metadata.name

              labels do
                add :app, spec.selector_app
                add :role, spec.role
              end
            end

            spec do
              type 'NodePort'

              selector do
                add :app, spec.selector_app
                add :role, spec.role
              end

              port do
                name 'http'
                port NGINX_PORT
                protocol 'TCP'
                target_port 'http'
              end
            end
          end

          @service.instance_eval(&block) if block
          @service
        end

        def service_account(&block)
          spec = self

          @service_account ||= KubeDSL.service_account do
            metadata do
              name "#{spec.selector_app}-#{spec.role}-sa"
              namespace spec.namespace.metadata.name

              labels do
                add :app, spec.selector_app
                add :role, spec.role
              end
            end
          end

          @service_account.instance_eval(&block) if block
          @service_account
        end

        def nginx_config(&block)
          spec = self

          @nginx_config ||= KubeDSL.config_map do
            metadata do
              name "#{spec.selector_app}-#{spec.role}-nginx-config"
              namespace spec.namespace.metadata.name
            end

            data do
              add 'nginx.conf', <<~END
                user  nginx;
                worker_processes  1;

                error_log  /var/log/nginx/error.log warn;
                pid        /var/run/nginx.pid;

                events {
                  worker_connections  1024;
                }

                http {
                  include       /etc/nginx/mime.types;
                  default_type  application/octet-stream;

                  log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                                    '$status $body_bytes_sent "$http_referer" '
                                    '"$http_user_agent" "$http_x_forwarded_for"';

                  access_log  /var/log/nginx/access.log  main;

                  sendfile           on;
                  keepalive_timeout  65;
                  gzip               on;

                  server {
                    listen #{NGINX_PORT};
                    server_name localhost;

                    location / {
                      root #{File.join(NGINX_MOUNT_PATH, 'current')};
                    }

                    error_page   500 502 503 504  /500.html;
                  }
                }
              END
            end
          end

          @nginx_config.instance_eval(&block) if block
          @nginx_config
        end

        def deployment(&block)
          kube_spec = self

          @deployment ||= KubeDSL.deployment do
            metadata do
              name "#{kube_spec.selector_app}-#{kube_spec.role}"
              namespace kube_spec.namespace.metadata.name

              labels do
                add :app, kube_spec.selector_app
                add :role, kube_spec.role
              end
            end

            spec do
              replicas 1

              selector do
                match_labels do
                  add :app, kube_spec.selector_app
                  add :role, kube_spec.role
                end
              end

              strategy do
                type 'RollingUpdate'

                rolling_update do
                  max_surge '25%'
                  max_unavailable 0
                end
              end

              template do
                metadata do
                  labels do
                    add :app, kube_spec.selector_app
                    add :role, kube_spec.role
                  end
                end

                spec do
                  container(:nginx) do
                    name "#{kube_spec.selector_app}-#{kube_spec.role}"
                    image_pull_policy 'IfNotPresent'
                    image "#{kube_spec.docker.metadata.image_url}:#{kube_spec.kubernetes.tag}"

                    port do
                      container_port NGINX_PORT
                      name 'http'
                      protocol 'TCP'
                    end

                    volume_mount do
                      name 'nginx-config'
                      mount_path '/etc/nginx/nginx.conf'
                      sub_path 'nginx.conf'
                    end

                    readiness_probe do
                      success_threshold 1
                      failure_threshold 2
                      initial_delay_seconds 5
                      period_seconds 3
                      timeout_seconds 1

                      http_get do
                        path '/500.html'
                        port NGINX_PORT
                        scheme 'HTTP'
                      end
                    end
                  end

                  volume do
                    name 'nginx-config'

                    config_map do
                      name kube_spec.nginx_config.metadata.name
                    end
                  end

                  restart_policy 'Always'
                  service_account_name kube_spec.service_account.metadata.name
                end
              end
            end
          end

          @deployment.instance_eval(&block) if block
          @deployment
        end

        def resources
          @resources ||= [
            service,
            service_account,
            nginx_config,
            deployment
          ]
        end

        def docker_images
          @docker_images ||= [docker_spec]
        end

        def namespace
          environment.kubernetes.namespace
        end

        def selector_app
          environment.kubernetes.selector_app
        end

        def role
          ROLE
        end

        def docker
          environment.docker
        end

        def kubernetes
          environment.kubernetes
        end

        def docker_images
          @docker_images ||= [
            Docker::Image.new(
              dockerfile,
              docker.metadata.image_url,
              docker.metadata.tags.map { |t| "#{t}-assets" }
            )
          ]
        end

        private

        def dockerfile
          @dockerfile ||= Docker::Dockerfile.new.tap do |df|
            require 'pry-byebug'
            binding.pry
            cur_tag = docker.tags.latest_timestamp_tag.to_s
            app_name = environment.app_name.downcase

            tags = begin
              [docker.tags.previous_timestamp_tag(cur_tag).to_s, cur_tag]
            rescue MissingTagError
              [cur_tag]
            end

            # this can handle more than 2 tags by virtue of using each_cons :)
            tags.each_cons(2) do |prev_tag, tag|
              prev_image_name = "#{app_name}-#{prev_tag}"
              df.from("#{docker.metadata.image_url}:#{prev_tag}", as: prev_image_name)
              df.run("mkdir -p #{RAILS_MOUNT_PATH}")
              df.run("bundle exec rake kuby:rails_app:assets:copy")

              if tag
                image_name = "#{app_name}-#{tag}"
                df.from("#{docker.metadata.image_url}:#{tag}", as: image_name)
                df.copy("--from=#{prev_image_name} #{RAILS_MOUNT_PATH}", RAILS_MOUNT_PATH)
              end

              df.run("bundle exec rake kuby:rails_app:assets:copy")
            end

            df.from(NGINX_IMAGE)
            df.copy("--from=#{"#{app_name}-#{tags[-1]}"} #{RAILS_MOUNT_PATH}", NGINX_MOUNT_PATH)
          end
        end
      end
    end
  end
end
