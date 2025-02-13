using Gee;

namespace Xmpp.Xep.Pubsub {
    public const string NS_URI = "http://jabber.org/protocol/pubsub";
    private const string NS_URI_EVENT = NS_URI + "#event";
    private const string NS_URI_OWNER = NS_URI + "#owner";
    public const string NS_URI_ERROR = NS_URI + "#errors";

    public const string ACCESS_MODEL_AUTHORIZE = "authorize";
    public const string ACCESS_MODEL_OPEN = "open";
    public const string ACCESS_MODEL_PRESENCE = "presence";
    public const string ACCESS_MODEL_ROSTER = "roster";
    public const string ACCESS_MODEL_WHITELIST = "whitelist";

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0060_pubsub_module");

        private HashMap<string, ItemListenerDelegate> item_listeners = new HashMap<string, ItemListenerDelegate>();
        private HashMap<string, RetractListenerDelegate> retract_listeners = new HashMap<string, RetractListenerDelegate>();
        private ArrayList<string> pep_subset_listeners = new ArrayList<string>();

        public void add_filtered_notification(XmppStream stream, string node, bool pep_subset,
                owned ItemListenerDelegate.ResultFunc? item_listener,
                owned RetractListenerDelegate.ResultFunc? retract_listener) {
            stream.get_module(ServiceDiscovery.Module.IDENTITY).add_feature_notify(stream, node);
            if (item_listener != null) {
                item_listeners[node] = new ItemListenerDelegate((owned)item_listener);
            }
            if (retract_listener != null) {
                retract_listeners[node] = new RetractListenerDelegate((owned)retract_listener);
            }
            if (pep_subset) {
                pep_subset_listeners.add(node);
            }
        }

        public void remove_filtered_notification(XmppStream stream, string node) {
            stream.get_module(ServiceDiscovery.Module.IDENTITY).remove_feature_notify(stream, node);
            item_listeners.unset(node);
            retract_listeners.unset(node);
        }

        public async Gee.List<StanzaNode>? request_all(XmppStream stream, Jid jid, string node) { // TODO multiple nodes gehen auch
            Iq.Stanza request_iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", NS_URI).add_self_xmlns().put_node(new StanzaNode.build("items", NS_URI).put_attribute("node", node)));
            request_iq.to = jid;

            Iq.Stanza iq_res = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, request_iq);

            StanzaNode event_node = iq_res.stanza.get_subnode("pubsub", NS_URI);
            if (event_node == null) return null;
            StanzaNode items_node = event_node.get_subnode("items", NS_URI);
            if (items_node == null) return null;

            return items_node.get_subnodes("item", NS_URI);
        }

        public delegate void OnResult(XmppStream stream, Jid jid, string? id, StanzaNode? node);
        public void request(XmppStream stream, Jid jid, string node, owned OnResult listener) { // TODO multiple nodes gehen auch
            Iq.Stanza request_iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", NS_URI).add_self_xmlns().put_node(new StanzaNode.build("items", NS_URI).put_attribute("node", node)));
            request_iq.to = jid;
            stream.get_module(Iq.Module.IDENTITY).send_iq(stream, request_iq, (stream, iq) => {
                StanzaNode event_node = iq.stanza.get_subnode("pubsub", NS_URI);
                StanzaNode items_node = event_node != null ? event_node.get_subnode("items", NS_URI) : null;
                StanzaNode item_node = items_node != null ? items_node.get_subnode("item", NS_URI) : null;
                string? id = item_node != null ? item_node.get_attribute("id", NS_URI) : null;
                listener(stream, iq.from, id, item_node != null ? item_node.sub_nodes[0] : null);
            });
        }

        public async bool publish(
                XmppStream stream, Jid? jid, string node_id, string? item_id, StanzaNode content,
                PublishOptions? publish_options = null,
                bool try_reconfiguring = true
        ) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("publish", NS_URI).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);
            StanzaNode items_node = new StanzaNode.build("item", NS_URI);
            if (item_id != null) items_node.put_attribute("id", item_id);
            items_node.put_node(content);
            publish_node.put_node(items_node);

            // Send along our requirements for the node
            if (publish_options != null) {
                StanzaNode publish_options_node = new StanzaNode.build("publish-options", NS_URI);
                pubsub_node.put_node(publish_options_node);

                DataForms.DataForm data_form = new DataForms.DataForm();
                DataForms.DataForm.HiddenField form_type_field = new DataForms.DataForm.HiddenField() { var="FORM_TYPE" };
                form_type_field.set_value_string(NS_URI + "#publish-options");
                data_form.add_field(form_type_field);

                foreach (string field_name in publish_options.settings.keys) {
                    DataForms.DataForm.Field field = new DataForms.DataForm.Field() { var=field_name };
                    field.set_value_string(publish_options.settings[field_name]);
                    data_form.add_field(field);
                }
                publish_options_node.put_node(data_form.get_submit_node());
            }

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);

            // If the node was configured differently before, reconfigure it to meet our requirements and try again
            Iq.Stanza iq_result = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            if (iq_result.is_error()) {
                if (publish_options == null || !try_reconfiguring) return false;
                bool precondition_not_met = iq_result.get_error().error_node.get_subnode("precondition-not-met", NS_URI_ERROR) != null;
                if (precondition_not_met) {
                    bool success = yield change_node_config(stream, jid, node_id, publish_options);
                    if (!success) return false;
                    return yield publish(stream, jid, node_id, item_id, content, publish_options, false);
                }
            }

            return true;
        }

        public async bool retract_item(XmppStream stream, Jid? jid, string node_id, string item_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("retract", NS_URI).put_attribute("node", node_id).put_attribute("notify", "true")
                    .put_node(new StanzaNode.build("item", NS_URI).put_attribute("id", item_id)));

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            bool ok = true;
            stream.get_module(Iq.Module.IDENTITY).send_iq(stream, iq, (stream, result_iq) => {
                ok = !result_iq.is_error();
                Idle.add(retract_item.callback);
            });
            yield;

            return ok;
        }

        public void delete_node(XmppStream stream, Jid? jid, string node_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("delete", NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            stream.get_module(Iq.Module.IDENTITY).send_iq(stream, iq, null);
        }

        public async DataForms.DataForm? request_node_config(XmppStream stream, Jid? jid, string node_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("configure", NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);

            Iq.Stanza iq = new Iq.Stanza.get(pubsub_node);
            Iq.Stanza result_iq = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            StanzaNode? data_form_node = result_iq.stanza.get_deep_subnode(Pubsub.NS_URI_OWNER + ":pubsub", Pubsub.NS_URI_OWNER + ":configure", "jabber:x:data:x");
            if (data_form_node == null) return null;
            return DataForms.DataForm.create_from_node(data_form_node);
        }

        public async bool submit_node_config(XmppStream stream, DataForms.DataForm data_form, string node_id) {
            StanzaNode submit_node = data_form.get_submit_node();

            StanzaNode pubsub_node = new StanzaNode.build("pubsub", Pubsub.NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("configure", Pubsub.NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);
            publish_node.put_node(submit_node);


            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            Iq.Stanza iq_result = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);

            return !iq_result.is_error();
        }

        public override void attach(XmppStream stream) {
            stream.get_module(MessageModule.IDENTITY).received_message.connect(on_received_message);
        }

        public override void detach(XmppStream stream) {
            stream.get_module(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }

        private void on_received_message(XmppStream stream, MessageStanza message) {
            StanzaNode event_node = message.stanza.get_subnode("event", NS_URI_EVENT);
            if (event_node == null) return;
            StanzaNode items_node = event_node.get_subnode("items", NS_URI_EVENT);
            if (items_node == null) return;
            string node = items_node.get_attribute("node", NS_URI_EVENT);

            if (!message.from.is_bare() && pep_subset_listeners.contains(node)) {
                warning("Got a PEP message from a full JID (%s), ignoring:\n%s", message.from.to_string(), message.stanza.to_string());
                return;
            }

            StanzaNode? item_node = items_node.get_subnode("item", NS_URI_EVENT);
            if (item_node != null) {
                string id = item_node.get_attribute("id", NS_URI_EVENT);

                if (item_listeners.has_key(node)) {
                    item_listeners[node].on_result(stream, message.from, id, item_node.sub_nodes[0]);
                }
            }

            StanzaNode? retract_node = items_node.get_subnode("retract", NS_URI_EVENT);
            if (retract_node != null) {
                string id = retract_node.get_attribute("id", NS_URI_EVENT);

                if (retract_listeners.has_key(node)) {
                    retract_listeners[node].on_result(stream, message.from, id);
                }
            }
        }

        private async bool change_node_config(XmppStream stream, Jid jid, string node, PublishOptions publish_options) {
            DataForms.DataForm? data_form = yield stream.get_module(Pubsub.Module.IDENTITY).request_node_config(stream, null, node);
            if (data_form == null) return false;

            foreach (DataForms.DataForm.Field field in data_form.fields) {
                if (publish_options.settings.has_key(field.var) && publish_options.settings[field.var] != field.get_value_string()) {
                    field.set_value_string(publish_options.settings[field.var]);
                }
            }
            return yield stream.get_module(Pubsub.Module.IDENTITY).submit_node_config(stream, data_form, node);
        }
    }

    public class PublishOptions {
        public HashMap<string, string> settings = new HashMap<string, string>();

        public PublishOptions set_persist_items(bool persist) {
            settings["pubsub#persist_items"] = persist.to_string();
            return this;
        }

        public PublishOptions set_max_items(string max) {
            settings["pubsub#max_items"] = max;
            return this;
        }

        public PublishOptions set_send_last_published_item(string send) {
            settings["pubsub#send_last_published_item"] = send.to_string();
            return this;
        }

        public PublishOptions set_access_model(string model) {
            settings["pubsub#access_model"] = model;
            return this;
        }
    }

    public class ItemListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid, string id, StanzaNode? node);
        public ResultFunc on_result { get; private owned set; }

        public ItemListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

    public class RetractListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid, string id);
        public ResultFunc on_result { get; private owned set; }

        public RetractListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

}
