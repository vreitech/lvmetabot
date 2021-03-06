import core.stdc.stdlib : free;
import std.stdio;
import std.file : exists, isFile;
import std.typecons;
import std.process : executeShell;
import std.conv;
import std.regex : regex, matchAll, replaceFirst, split;
import std.process;
import std.algorithm.searching : canFind;
import core.time : Duration, seconds;
import vibe.data.json;
import vibe.core.core;
import vibe.core.log : logInfo, logWarn, logError;
import vibe.http.server;
import vibe.http.router;
import vibe.stream.tls;
import telega.botapi : BotApi, BaseApiUrl, WebhookInfo, ParseMode, SendMessageMethod;
import telega.drivers.requests : RequestsHttpClient;
import dyaml;

/// Array of supported protocols
const string[] c_protos = ["http", "https"];

/// Name of application config file to try
const string[] g_yamlConfigFileName = [`lvmetabot.yml`, `/etc/lvmetabot.yml`];

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

/// Global settings opject
GlobalSettings g_globalSettings;

/// Global command execution gap (deny command execution in gap time after previous execution)
Duration g_execGap;

/// Global array of bot names and settings
Node* [string] g_botNames;

/// Main loop
int main()
{
	logInfo("lvmetabot started.");
	scope(exit) {
		foreach(p; g_botNames) {
			free(p);
		}
		logInfo("lvmetabot exited.");
	}
	bool noConfigFile = true;
	ushort configFileIndex;

	for(ushort i = 0; i < g_yamlConfigFileName.length; i++) {
		if(g_yamlConfigFileName[i].exists
			&& g_yamlConfigFileName[i].isFile
		) {
			noConfigFile = false;
			configFileIndex = i;
			break;
		}
	}
	if(noConfigFile) {
		logError("[!] config file not found, exiting.");
		return -1;
	}

	auto yConf = Loader.fromFile(g_yamlConfigFileName[configFileIndex]).load();

	if("globalExecGap" in yConf) {
		g_execGap = yConf["globalExecGap"].as!ushort.seconds;
	} else {
		g_execGap = 10.seconds;
	}

	{
		auto f1 = "settings";
		if(f1 in yConf
			&& yConf[f1].type == NodeType.mapping
			&& yConf[f1].length >= 1
		)
		{
			{
				auto f2 = "bindProto";
				if(!f2 in yConf[f1]
					|| !yConf[f1][f2].type == NodeType.mapping
					|| !c_protos.canFind(yConf[f1][f2].as!string)
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or wrong proto, exiting.");
					return -21;
				}
				g_globalSettings.bindProto = yConf[f1][f2].as!string;
			}
			{
				auto f2 = "bindAddress";
				if(!f2 in yConf[f1]
					|| !yConf[f1][f2].type == NodeType.mapping
					||  yConf[f1][f2].as!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -22;
				}
				g_globalSettings.bindAddress = yConf[f1][f2].as!string;
			}
			{
				auto f2 = "bindPort";
				if(!f2 in yConf[f1]
					|| !yConf[f1][f2].type == NodeType.mapping
					||  yConf[f1][f2].as!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -23;
				}
				g_globalSettings.bindPort = yConf[f1][f2].as!ushort;
			}
			if(g_globalSettings.bindProto == "https") {
				auto f2 = "keyFileName";
				if(!f2 in yConf[f1]
					|| !yConf[f1][f2].type == NodeType.mapping
					||  yConf[f1][f2].as!string == ""
					|| !yConf[f1][f2].as!string.exists
					|| !yConf[f1][f2].as!string.isFile
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or no file with that name, exiting.");
					return -24;
				}
				g_globalSettings.keyFileName = yConf[f1][f2].as!string;
			}
			if(g_globalSettings.bindProto == "https") {
				auto f2 = "certFileName";
				if(!f2 in yConf[f1]
					|| !yConf[f1][f2].type == NodeType.mapping
					||  yConf[f1][f2].as!string == ""
					|| !yConf[f1][f2].as!string.exists
					|| !yConf[f1][f2].as!string.isFile
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, or no file with that name, exiting.");
					return -25;
				}
				g_globalSettings.certFileName = yConf[f1][f2].as!string;
			}
			{
				auto f2 = "domainName";
				if(!f2 in yConf[f1]
					|| !yConf[f1][f2].type == NodeType.mapping
					||  yConf[f1][f2].as!string == ""
				) {
					logError("[!] " ~ f1 ~ "." ~ f2 ~ " mapping not found in config, exiting.");
					return -26;
				}
				g_globalSettings.domainName = yConf[f1][f2].as!string;
			}
		} else {
			logError("[!] " ~ f1 ~ " mapping not found in config, exiting.");
			return -2;
		}
	}

	/// Filling g_botNames from config
	{
		auto f1 = "botTree";
		if(f1 in yConf
			&& yConf[f1].type == NodeType.mapping
			&& yConf[f1].length >= 1
		) {
			debug { logInfo("D (processing): " ~ f1 ~ ".length == " ~ yConf[f1].length.to!string); }
			foreach(ref Node botKey, ref Node botValue; yConf[f1]) {
				debug { logInfo("D (processing): botKey == " ~ botKey.as!string ~ " : botValue == " ~ (botValue.type == NodeType.mapping?"<mapping>":botValue.as!string)); }
				if(botValue.type == NodeType.mapping
					&& botInit(botKey.as!string, botValue) == true
				) {
					g_botNames[botKey.as!string] = &botValue;
				}
			}
		} else {
			logError("[!] " ~ f1 ~ " mapping not found in config, exiting.");
			return -3;
		}
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
bool botInit(in string botName, in ref Node botNode) {
	debug { logInfo("D botInit[" ~ botName ~ "] entered."); scope(exit) { logInfo("D botInit[" ~ botName ~ "] exited."); } }
	debug { logInfo("D botInit[" ~ botName ~ "] processing."); }

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

	// Try to set webhook, if it's not set
	if(!webhookInfo.url) {
		api.setWebhook(`https://` ~ g_globalSettings.domainName ~ botNode["botUrl"].as!string);
	}

	destroy(api);
	destroy(client);
	return true;
}

/// Function for process incoming messages
void botProcess(HTTPServerRequest req, HTTPServerResponse res) {
	debug { logInfo("D botProcess entered."); }

	string botName;

	scope(exit) {
		res.writeBody(`{"ok": "true"}`);
		debug { logInfo("D botProcess exited."); }
	}

	/// Determining according bot or nether
	foreach(string botKey, Node* botValue; g_botNames) {
		debug { logInfo("D botProcess: (req.params['bot_url'] == " ~ "/" ~ req.params["bot_url"] ~ ") ==? (botValue['botUrl'] == " ~ (*botValue)["botUrl"].as!string ~ ")"); }
		if((*botValue)["botUrl"].as!string == ("/" ~ req.params["bot_url"])) {
			debug { logInfo("D botProcess: req.params['bot_url'] equals to botValue['botUrl']"); }
			botName = botKey;
			break;
		}
		return;
	}
	debug { logInfo("D botProcess: req.requestURI == " ~ req.requestURI ~ ", req.requestPath == ", req.requestPath); }
	debug { logInfo("D botProcess: req.params['bot_url'] == " ~ req.params["bot_url"] ~ ", req.json['message'] ==\n" ~ req.json["message"].toPrettyString); }
	debug { logInfo("D botProcess: from.id == " ~ req.json["message"]["from"]["id"].toString ~ ", chat.id == " ~ req.json["message"]["chat"]["id"].toString); }

	/// Objects for sending message to telegram API
	auto client = new RequestsHttpClient();
	auto api = new BotApi((*g_botNames[botName])["botToken"].as!string, BaseApiUrl, client);
	auto m = SendMessageMethod();

	/// Determining command
	auto re = regex(`^\/(.*?)(?:@` ~ botName ~ `)?(?=$|\s)`,`g`);
	auto rCommand = replaceFirst(req.json["message"]["text"].get!string, re, `$1`);
	debug { logInfo("D botProcess: rCommand == " ~ rCommand); }
// split into ["first_word", "other words"]
/*	auto splitCommand = split(rCommand, regex(`(?<=^\S+)\s`)); */
	auto splitCommand = split(rCommand, regex(`\s+`));
	debug { logInfo("D botProcess: splitCommand == " ~ splitCommand.to!string); }

	with((*g_botNames[botName])["commands"]) {
		if(
			req.json["message"]["entities"][0]["type"] == "bot_command"
			&& containsKey(splitCommand[0])
		) {
			debug { logInfo("D botProcess: splitCommand[0] in botName.commands"); }

			/// Determining permissions
			debug { logInfo("D botProcess: determining permissions"); }
			debug { logInfo("D botProcess: determining permissionChatIdMapping"); }
			with(opIndex(splitCommand[0])) {
				if(
					!containsKey("permissionChatIdMapping")
					|| !opIndex("permissionChatIdMapping").containsKey(req.json["message"]["chat"]["id"].get!long)
					|| !opIndex("permissionChatIdMapping")[req.json["message"]["chat"]["id"].get!long].contains(req.json["message"]["from"]["id"].get!long)
				) {
					debug { logInfo("D botProcess: from.id not found"); }
					logWarn(
						"[W] '" ~ ("first_name" in req.json["message"]["from"]?req.json["message"]["from"]["first_name"].get!string:"")
						~ ("last_name" in req.json["message"]["from"]?" " ~ req.json["message"]["from"]["last_name"].get!string:"")
						~ "' have not permission to execute '" ~ splitCommand[0] ~ "'"
					);
					m.chat_id = req.json["message"]["chat"]["id"].get!ulong;
					m.text = "<b>"
					~ "'" ~ ("first_name" in req.json["message"]["from"]?req.json["message"]["from"]["first_name"].get!string:"")
					~ ("last_name" in req.json["message"]["from"]?" " ~ req.json["message"]["from"]["last_name"].get!string:"")
					~ "' have not permission to execute '" ~ splitCommand[0] ~ "'"
					~ "</b>";
					m.parse_mode = ParseMode.HTML;
					m.disable_notification = true;
					api.sendMessage(m);
					destroy(api);
					destroy(client);
					return;
				}
				else debug { logInfo("D botProcess: permissions is OK"); }

				/// Executing command
				if(containsKey("exec")) {
					logInfo(
						"[I] Execute '" ~ opIndex("exec").as!string
						~ "' by '" ~ req.json["message"]["from"]["id"].get!long.to!string ~ " ("
						~ ("first_name" in req.json["message"]["from"]?req.json["message"]["from"]["first_name"].get!string:"")
						~ ("last_name" in req.json["message"]["from"]?" " ~ req.json["message"]["from"]["last_name"].get!string:"") ~ ")'"
					);
					m.chat_id = req.json["message"]["chat"]["id"].get!ulong;
					m.text = "<code>"
					~ executeShell(
							opIndex("exec").as!string
	// disabled as potentially insecure
	//						~ (splitCommand.length > 1 && !matchAll(splitCommand[1], r"[;&!$%+=^`]")?" " ~ splitCommand[1]:"")
						).output
					~ "</code>";
					m.parse_mode = ParseMode.HTML;
					m.disable_notification = true;
					api.sendMessage(m);
				} else debug { logInfo("D botProcess: command '" ~ splitCommand[0] ~ "' have not 'exec' string in config."); }
			}

			destroy(api);
			destroy(client);
		} else {
			debug { logInfo("D botProcess: not a command."); }
		}
	}
}
