import std.stdio;
import std.file;
import std.typecons;
import std.process;
import vibe.data.json;
import vibe.core.core;
import vibe.core.log;
import dyaml;

/// Name of application config file
const string g_yamlConfigFileName = `config.yml`;
/// Global command execution gap (deny command execution in gap after previous execution)
Duration g_execGap;
/// Global bot token
string g_botToken = `1017280662:AAHu5nNmBOilY2QuRDJws0kAtqMEDCDQqL8`;
/// Global array of values
string[string] g_values;

void main()
{
	
}
