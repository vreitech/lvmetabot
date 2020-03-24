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
string g_botToken;
/// Global array of bots
Node[string] g_botTree;

int main()
{
	logInfo("lvmetabot started.");
	scope(exit) {
		logInfo("lvmetabot exited.");
	}
	if(!g_yamlConfigFileName.exists) {
		logError("[!] config file name doesn't point at any file system entry, exiting.");
		return -1;
	}
	if(!g_yamlConfigFileName.isFile) {
		logError("[!] config file name doesn't point at regular file, exiting.");
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
	}
	if("botTree" in yamlConfig && yamlConfig["botTree"].type == NodeType.mapping && yamlConfig["botTree"].length) {
		foreach(ref Node botKey, ref Node botValue; yamlConfig["botTree"]) {
			logInfo("D: " ~ botKey.get!string ~ " : " ~ (botValue.type == NodeType.mapping)?"<mapping>":botValue.get!string);
			g_botTree[botKey.get!string] = botValue;
		}
	} else {
		logError("[!] botTree mapping not found in config, exiting.");
		return -3;
	}
	
	return 0;
}
