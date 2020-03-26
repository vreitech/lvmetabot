import std.stdio;
import std.file : exists, isFile;
import std.typecons;
import std.process;
import std.conv;
import core.time : Duration, seconds;
import vibe.data.json;
import vibe.core.core;
import vibe.core.log : logInfo, logWarn, logError;
import vibe.http.server;
import vibe.http.router;
import vibe.stream.tls;
import telega.botapi : BotApi, BaseApiUrl, WebhookInfo;
import telega.drivers.requests : RequestsHttpClient;
import dyaml;

/// Array of supported protocols
const string[] c_protos = ["http", "https"];

/// Name of application config file
const string g_yamlConfigFileName = `config.yml`;
/// Global command execution gap (deny command execution in gap after previous execution)
Duration g_execGap;

/// Structure for global settings from config
struct GlobalSettings {
	/// Global bind protocol
	string bindProto;
	/// Global bind IP address
	string bindAddress;
	/// Global bind port
	ushort bindPort;
	/// Global domain name
	string domainName;
	/// Global key file
	string keyFileName;
	/// Global certificate file
	string certFileName;
}

/// Global settings
GlobalSettings g_globalSettings;

/// Global array of bots
Node[string] g_botTree;

int main()
{
	logInfo("lvmetabot started.");
	scope(exit) {
		logInfo("lvmetabot exited.");
	}
	if(!g_yamlConfigFileName.exists
		|| !g_yamlConfigFileName.isFile
		) {
		logError("[!] config file name doesn't point to file, exiting.");
		return -1;
	}

	Node yamlConfig = Loader.fromFile(g_yamlConfigFileName).load();

	if("globalExecGap" in yamlConfig) {
		g_execGap = yamlConfig["globalExecGap"].as!ushort.seconds;
	} else {
		g_execGap = 10.seconds;
	}

	{
		auto f1 = "settings";
		if(f1 in yamlConfig
			&& yamlConfig[f1].type == NodeType.mapping
			&& yamlConfig[f1].length >= 1
		)
		{
			{
				auto f2 = "bindProto";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					|| !c_protos.canFind(yamlConfig[f1][f2].get!string)
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or wrong proto, exiting.");
					return -21;
				}
				g_globalSettings.bindProto = yamlConfig[f1][f2].get!string;
			}
			{
				auto f2 = "bindAddress";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -22;
				}
				g_globalSettings.bindAddress = yamlConfig[f1][f2].get!string;
			}
			{
				auto f2 = "bindPort";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -23;
				}
				g_globalSettings.bindPort = yamlConfig[f1][f2].get!ushort;
			}
			if(g_globalSettings.bindProto == "https") {
				auto f2 = "keyFileName";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
					|| !yamlConfig[f1][f2].get!string.exists
					|| !yamlConfig[f1][f2].get!string.isFile
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or no file with that name, exiting.");
					return -24;
				}
				g_globalSettings.keyFileName = yamlConfig[f1][f2].get!string;
			}
			if(g_globalSettings.bindProto == "https") {
				auto f2 = "certFileName";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
					|| !yamlConfig[f1][f2].get!string.exists
					|| !yamlConfig[f1][f2].get!string.isFile
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or no file with that name, exiting.");
					return -25;
				}
				g_globalSettings.certFileName = yamlConfig[f1][f2].get!string;
			}
			{
				auto f2 = "domainName";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -26;
				}
				g_globalSettings.domainName = yamlConfig[f1][f2].get!string;
			}
		} else {
			logError("[!] " ~ f1 ~ " mapping not found in config, exiting.");
			return -2;
		}
	}

	{
		auto f1 = "botTree";
		if(f1 in yamlConfig
			&& yamlConfig[f1].type == NodeType.mapping
			&& yamlConfig[f1].length >= 1
		) {
			debug { logInfo("D (processing): " ~ f1 ~ ".length == " ~ yamlConfig[f1].length.to!string); }
			foreach(ref Node botKey, ref Node botValue; yamlConfig[f1]) {
				debug { logInfo("D (processing): botKey == " ~ botKey.get!string ~ " : botValue == " ~ (botValue.type == NodeType.mapping?"<mapping>":botValue.get!string)); }
				if(botValue.type == NodeType.mapping
					&& botInit(botKey.get!string, botValue) == true
				) {
					g_botTree[botValue["botUrl"].get!string] = botValue;
				}
			}
		} else {
			logError("[!] " ~ f1 ~ " mapping not found in config, exiting.");
			return -3;
		}
	}

	foreach(key; g_botTree) {
		logInfo("D: ", key);
	}

	auto settings = new HTTPServerSettings;
	settings.port = g_globalSettings.bindPort;
	settings.bindAddresses = [g_globalSettings.bindAddress];
	if(g_globalSettings.bindProto == "https") {
		settings.tlsContext = createTLSContext(TLSContextKind.server);
		settings.tlsContext.useCertificateChainFile(g_globalSettings.certFileName);
		settings.tlsContext.usePrivateKeyFile(g_globalSettings.keyFileName);
	}

	auto router = new URLRouter;
	
	router.post("/:bot_url", &botProcess);
	listenHTTP(settings, router);

	return runApplication();
}

/// Function for init botNode's
bool botInit(in string botName, in Node botNode) {
	debug { logInfo("D botInit[" ~ botName ~ "] entered."); scope(exit) { logInfo("D botInit[" ~ botName ~ "] exited."); } }
	debug { logInfo("D botInit[" ~ botName ~ "].botChat == " ~ botNode["botChat"].get!string); }

	if(!botNode["botToken"].as!string) {
		logError("[!] " ~ botName ~ " botToken not found in config, return from thread."); return false;
	}
	if(!botNode["botUrl"].as!string) {
		logError("[!] " ~ botName ~ " botUrl not found in config, return from thread."); return false;
	}

	auto client = new RequestsHttpClient();
	auto api = new BotApi(botNode["botToken"].as!string, BaseApiUrl, client);
	WebhookInfo webhookInfo;
	try {
		 webhookInfo = api.getWebhookInfo;
	} catch(Exception e) {
		logWarn("[W] botInit[" ~ botName ~ "] api.getWebhookInfo exception: " ~ e.msg);
		return false;
	}
	debug { logInfo("D botInit[" ~ botName
		~ "] webhookInfo.url == " ~ webhookInfo.url
		~ ", webhookInfo.has_custom_certificate == " ~ webhookInfo.has_custom_certificate.to!string
	); }

	if(!webhookInfo.url) {
		api.setWebhook(g_globalSettings.bindProto ~ `://` ~ g_globalSettings.domainName ~ botNode["botUrl"].as!string);
	}

	return true;
}

/// Function for process incoming messages
void botProcess(HTTPServerRequest req, HTTPServerResponse res) {
	debug { logInfo("D botProcess entered."); scope(exit) { res.writeBody(`{"ok": "true"}`); logInfo("D botProcess exited."); } }

	if(!g_botTree[req.params["bot_url"]].isValid) { return; }
	debug { logInfo("D botProcess: req.params['bot_url'] == " ~ req.params["bot_url"] ~ ", req.json['message'] == " ~ req.json["message"].to!string); }
}
