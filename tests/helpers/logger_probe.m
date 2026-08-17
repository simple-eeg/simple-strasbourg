function logger_probe
%LOGGER_PROBE Minimal caller copied into an isolated synthetic project.
log_command_window('start');
fprintf('SIMPLE_ISOLATED_LOGGER_TOKEN\n');
log_command_window('stop');
end
