import std.stdio;
import std.file;
import std.typecons;
import std.process;
import core.time;
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
/// Global array of bots
string[string] g_bots;

int main()
{
	if(!g_yamlConfigFileName.exists) {
		logError("Config file name doesn't point at any file system entry! Exitting...");
		return -1;
	}
	if(!g_yamlConfigFileName.isFile) {
		logError("Config file name doesn't point at regular file! Exitting...");
		return -2;
	}

	Node yamlConfig = Loader.fromFile(g_yamlConfigFileName).load();

	if("execGap" in yamlConfig) {
		g_execGap = yamlConfig["execGap"].as!ushort.seconds;
	} else {
		g_execGap = 10.seconds;
	}
	if("botToken" in yamlConfig) {
		g_botToken = yamlConfig["botToken"].as!string;
	} else {
		g_botToken = `unk`;
	}

	return 0;
}
