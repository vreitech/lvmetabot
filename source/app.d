import std.stdio;
import std.file;
import std.typecons;
import std.process;
import std.conv;
import core.time;
import vibe.data.json;
import vibe.core.core;
import vibe.core.log;
import vibe.http.server;
import vibe.http.router;
import vibe.stream.tls;
import telega.botapi;
import telega.drivers.requests : RequestsHttpClient;
import dyaml;

/// Name of application config file
const string g_yamlConfigFileName = `config.yml`;
/// Global command execution gap (deny command execution in gap after previous execution)
Duration g_execGap;
/// Global domain name
string g_domainName;
/// Global key file
string g_keyFileName;
/// Global certificate file
string g_certFileName;
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
				auto f2 = "keyFileName";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
					|| !yamlConfig[f1][f2].get!string.exists
					|| !yamlConfig[f1][f2].get!string.isFile
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or no file with that name, exiting.");
					return -21;
				}
				g_keyFileName = yamlConfig[f1][f2].get!string;
			}
			{
				auto f2 = "certFileName";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
					|| !yamlConfig[f1][f2].get!string.exists
					|| !yamlConfig[f1][f2].get!string.isFile
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or no file with that name, exiting.");
					return -22;
				}
				g_certFileName = yamlConfig[f1][f2].get!string;
			}
			{
				auto f2 = "domainName";
				if(!f2 in yamlConfig[f1]
					|| !yamlConfig[f1][f2].type == NodeType.mapping
					||  yamlConfig[f1][f2].get!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -23;
				}
				g_domainName = yamlConfig[f1][f2].get!string;
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

	auto settings = new HTTPServerSettings;
	settings.port = 443;
	settings.bindAddresses = ["0.0.0.0"];
	settings.tlsContext = createTLSContext(TLSContextKind.server);
	settings.tlsContext.useCertificateChainFile("server-cert.pem");
	settings.tlsContext.usePrivateKeyFile("server-key.pem");

	auto router = new URLRouter;
	
	router.post("/:bot_url", &botProcess);
	listenHTTP(settings, router);

	return runApplication();
}

bool botInit(in string botName, in Node botNode) {
	debug { logInfo("D botInit[" ~ botName ~ "] entered."); scope(exit) { logInfo("D botInit[" ~ botName ~ "] exited."); } }
	debug { logInfo("D botInit[" ~ botName ~ "].botChat == " ~ botNode["botChat"].get!string); }

	if(!botNode["botToken"].as!string) { logError("[!] " ~ botName ~ " botToken not found in config, return from thread."); return false; }
	if(!botNode["botUrl"].as!string) { logError("[!] " ~ botName ~ " botUrl not found in config, return from thread."); return false; }

	auto client = new RequestsHttpClient();
	auto api = new BotApi(botNode["botToken"].as!string, BaseApiUrl, client);
	WebhookInfo webhookInfo;
	try {
		 webhookInfo = api.getWebhookInfo;
	} catch(telega.botapi.TelegramBotApiException e) {
		logWarn("[W] botInit api.getWebhookInfo exception: " ~ e.msg);
		return false;
	}
	debug { logInfo("D botInit[" ~ botName
		~ "] webhookInfo.url == " ~ webhookInfo.url
		~ ", webhookInfo.has_custom_certificate == " ~ webhookInfo.has_custom_certificate.to!string
	); }

	if(!webhookInfo.url) {
		api.setWebhook(`https://` ~ g_domainName ~ botNode["botUrl"].as!string);
	}

	return true;
}

void botProcess(HTTPServerRequest req, HTTPServerResponse res) {
	debug { logInfo("D botProcess entered."); scope(exit) { res.writeBody(`{"ok": "true"}`); logInfo("D botProcess exited."); } }

	if(!g_botTree[req.params["bot_url"]].isValid) { return; }
	debug { logInfo("D botProcess: req.params['bot_url'] == " ~ req.params["bot_url"] ~ ", req.json['message'] == " ~ req.json["message"].to!string); }
}
